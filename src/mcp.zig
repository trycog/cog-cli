const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const code_intel = @import("code_intel.zig");
const config_mod = @import("config.zig");
const client = @import("client.zig");
const debug_server_mod = @import("debug/server.zig");
const debug_mod = @import("debug.zig");
const observe_server_mod = @import("observe/server.zig");
const watcher_mod = @import("watcher.zig");
const git_state = @import("git_state.zig");
const paths = @import("paths.zig");
const debug_log_mod = @import("debug_log.zig");
const memory_mod = @import("memory.zig");
const repo_context_mod = @import("repo_context.zig");
const session_context_mod = @import("session_context.zig");
const memory_envelope_mod = @import("memory_envelope.zig");
const settings_mod = @import("settings.zig");
const update_check_mod = @import("update_check.zig");

const Config = config_mod.Config;
const DebugServer = debug_server_mod.DebugServer;
const ObserveServer = observe_server_mod.ObserveServer;

// ── MCP Server ──────────────────────────────────────────────────────────

var server_version: []const u8 = "0.0.0";
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const RemoteTool = struct {
    name: []const u8, // local name: "mem_recall"
    remote_name: []const u8, // server name: "cog_recall"
    description: []const u8,
    input_schema: []const u8, // raw JSON string
};

const StaticToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

const code_tool_definitions = [_]StaticToolDef{
    .{
        .name = "code_query",
        .description = "Targeted code index query tool. ALWAYS batch every query into one 'queries' array call. Modes: 'find', 'refs', 'symbols', 'imports', 'contains', 'calls', 'callers', 'overview'. Flat parameters (mode, name, file, etc.) are only for genuinely single queries.",
        .input_schema =
        \\{"type":"object","properties":{"queries":{"type":"array","description":"REQUIRED for multiple queries. Each entry specifies its own mode, name, file, kind, direction, and scope. Always combine sequential code_query calls into one batched call using this array.","items":{"type":"object","properties":{"mode":{"type":"string","description":"Query mode: 'find', 'refs', 'symbols', 'imports', 'contains', 'calls', 'callers', or 'overview'"},"name":{"type":"string","description":"Symbol name (supports glob: '*', '?', '|')"},"file":{"type":"string","description":"File path for file-scoped queries"},"kind":{"type":"string","description":"Filter by symbol kind"},"direction":{"type":"string","description":"'incoming', 'outgoing', or 'both'"},"scope":{"type":"string","description":"Overview scope: 'symbol', 'file', or 'repo'"}},"required":["mode"]}},"mode":{"type":"string","description":"Query mode (single-query only — use 'queries' array for multiple): 'find', 'refs', 'symbols', 'imports', 'contains', 'calls', 'callers', or 'overview'"},"name":{"type":"string","description":"Symbol name (supports glob: '*', '?', '|')"},"file":{"type":"string","description":"File path for file-scoped queries"},"kind":{"type":"string","description":"Filter by symbol kind"},"direction":{"type":"string","description":"'incoming', 'outgoing', or 'both'"},"scope":{"type":"string","description":"Overview scope: 'symbol', 'file', or 'repo'"}}}
        ,
    },
    .{
        .name = "code_explore",
        .description = "Primary code exploration tool. ALWAYS batch all candidate symbols into one 'queries' array call. Returns readable plain-text summaries with definition bodies, per-file outlines, and optional architecture sections such as imports, containment, and overview data.",
        .input_schema =
        \\{"type":"object","properties":{"queries":{"type":"array","description":"REQUIRED. All symbol lookups MUST go into this single array. Do not split symbols across multiple code_explore calls.","items":{"type":"object","properties":{"name":{"type":"string","description":"Symbol name (supports glob: '*init*', 'get*')"},"kind":{"type":"string","description":"Filter by symbol kind (function, struct, method, variable, etc.)"}},"required":["name"]}},"context_lines":{"type":"number","description":"Fallback context lines for simple definitions without braces (default: 15)"},"include_relationships":{"type":"boolean","description":"Include symbol-level relationship summaries such as containment and imports when available"},"include_architecture":{"type":"boolean","description":"Include architecture-oriented summaries. Recommended for repository overview tasks."},"overview_scope":{"type":"string","description":"Architecture summary scope: 'symbol', 'file', or 'repo'"}},"required":["queries"]}
        ,
    },
};

const ToolTier = debug_server_mod.ToolTier;

const MAX_HANDLER_CONCURRENCY: usize = 8;
const handler_wait_poll_ns: u64 = 10 * std.time.ns_per_ms;
const watcher_poll_interval_ms: i32 = 50;

const IndexGeneration = struct {
    inode: std.fs.File.INode,
    size: u64,
    mtime: i128,

    fn eql(self: IndexGeneration, other: IndexGeneration) bool {
        return self.inode == other.inode and self.size == other.size and self.mtime == other.mtime;
    }
};
const handler_shutdown_grace_ns: u64 = 2 * std.time.ns_per_s;

const HandlerThreads = struct {
    const State = enum { empty, running, complete };
    const DrainResult = enum { complete, timed_out };

    const Slot = struct {
        state: State = .empty,
        thread: ?std.Thread = null,
    };

    slots: [MAX_HANDLER_CONCURRENCY]Slot = [_]Slot{.{}} ** MAX_HANDLER_CONCURRENCY,
    limit: usize,
    accepting: bool = true,
    capacity_waiters: usize = 0,
    mutex: std.Thread.Mutex = .{},
    available: std.Thread.Condition = .{},

    fn init(limit: usize) HandlerThreads {
        std.debug.assert(limit > 0 and limit <= MAX_HANDLER_CONCURRENCY);
        return .{ .limit = limit };
    }

    fn begin(self: *HandlerThreads) ?usize {
        while (true) {
            var completed_thread: ?std.Thread = null;
            var completed_slot: usize = 0;

            self.mutex.lock();
            if (!self.accepting or shutdown_requested.load(.acquire)) {
                self.mutex.unlock();
                debug_log_mod.log("mcp.handlers: rejecting request after shutdown", .{});
                return null;
            }

            for (self.slots[0..self.limit], 0..) |*slot, i| {
                if (slot.state == .complete and slot.thread != null) {
                    completed_thread = slot.thread;
                    completed_slot = i;
                    slot.* = .{};
                    break;
                }
            }

            if (completed_thread) |thread| {
                self.mutex.unlock();
                debug_log_mod.log("mcp.handlers: joining completed slot={d}", .{completed_slot});
                thread.join();
                continue;
            }

            for (self.slots[0..self.limit], 0..) |*slot, i| {
                if (slot.state == .empty) {
                    slot.state = .running;
                    self.mutex.unlock();
                    debug_log_mod.log("mcp.handlers: reserved slot={d}", .{i});
                    return i;
                }
            }

            debug_log_mod.log("mcp.handlers: concurrency cap reached limit={d}; timed wait", .{self.limit});
            self.capacity_waiters += 1;
            self.available.timedWait(&self.mutex, handler_wait_poll_ns) catch |err| switch (err) {
                error.Timeout => debug_log_mod.log("mcp.handlers: capacity wait timed out; rechecking shutdown", .{}),
            };
            self.capacity_waiters -= 1;
            self.available.broadcast();
            self.mutex.unlock();
        }
    }

    fn track(self: *HandlerThreads, slot_index: usize, thread: std.Thread) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = &self.slots[slot_index];
        std.debug.assert(slot.state != .empty and slot.thread == null);
        slot.thread = thread;
        self.available.broadcast();
        debug_log_mod.log("mcp.handlers: tracking slot={d}", .{slot_index});
    }

    fn cancel(self: *HandlerThreads, slot_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = &self.slots[slot_index];
        std.debug.assert(slot.state == .running and slot.thread == null);
        slot.* = .{};
        self.available.broadcast();
        debug_log_mod.log("mcp.handlers: released unspawned slot={d}", .{slot_index});
    }

    fn finish(self: *HandlerThreads, slot_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = &self.slots[slot_index];
        std.debug.assert(slot.state == .running);
        slot.state = .complete;
        self.available.broadcast();
        debug_log_mod.log("mcp.handlers: completed slot={d}", .{slot_index});
    }

    fn stopAccepting(self: *HandlerThreads) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.accepting) return;
        self.accepting = false;
        self.available.broadcast();
        debug_log_mod.log("mcp.handlers: stopped accepting requests", .{});
    }

    fn drain(self: *HandlerThreads, timeout_ns: u64) DrainResult {
        debug_log_mod.log("mcp.handlers: draining in-flight requests timeout_ns={d}", .{timeout_ns});
        var timer = std.time.Timer.start() catch {
            debug_log_mod.log("mcp.handlers: shutdown timer unavailable; refusing unbounded drain", .{});
            return .timed_out;
        };

        while (true) {
            var completed_thread: ?std.Thread = null;
            var completed_slot: usize = 0;
            var has_in_flight = false;

            self.mutex.lock();
            if (self.capacity_waiters > 0) has_in_flight = true;
            for (self.slots[0..self.limit], 0..) |*slot, i| {
                if (slot.state == .complete and slot.thread != null) {
                    completed_thread = slot.thread;
                    completed_slot = i;
                    slot.* = .{};
                    break;
                }
                if (slot.state != .empty) has_in_flight = true;
            }

            if (completed_thread) |thread| {
                self.mutex.unlock();
                debug_log_mod.log("mcp.handlers: joining drain slot={d}", .{completed_slot});
                thread.join();
                continue;
            }

            if (!has_in_flight) {
                self.mutex.unlock();
                debug_log_mod.log("mcp.handlers: drain complete", .{});
                return .complete;
            }

            const elapsed_ns = timer.read();
            if (elapsed_ns >= timeout_ns) {
                self.mutex.unlock();
                debug_log_mod.log("mcp.handlers: drain deadline exceeded elapsed_ns={d}; process exit required", .{elapsed_ns});
                return .timed_out;
            }

            const remaining_ns = timeout_ns - elapsed_ns;
            const wait_ns = @min(remaining_ns, handler_wait_poll_ns);
            debug_log_mod.log("mcp.handlers: timed wait for in-flight completion wait_ns={d}", .{wait_ns});
            self.available.timedWait(&self.mutex, wait_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
            self.mutex.unlock();
        }
    }
};

/// A due update notice staged for the agent: the pre-formatted line to
/// prepend and the bare latest version to confirm via markNotified once the
/// line is actually delivered. Both are allocator-owned.
const PendingUpdateNotice = struct {
    line: []const u8,
    latest: []const u8,
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    mem_config: ?Config,
    brain_type: config_mod.BrainType,
    mem_db: ?memory_mod.MemoryDb = null,
    debug_server: DebugServer,
    observe_enabled: bool,
    observe_server: ?ObserveServer,
    code_cache: ?code_intel.CodeIndex = null,
    code_cache_generation: ?IndexGeneration = null,
    // Nonzero while any reindex — reconcile worker or watcher batch — is in
    // flight; code tools disclose possible staleness instead of answering
    // with silent confidence. A counter because the windows can overlap.
    index_sync_pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    remote_tools: ?[]RemoteTool = null,
    mcp_session_id: ?[]const u8 = null,
    session_contexts: std.StringHashMapUnmanaged(session_context_mod.SessionContext) = .empty,
    remote_memory_capabilities: memory_envelope_mod.RemoteMemoryCapabilities = .{},
    repo_context_cache: std.StringHashMapUnmanaged(repo_context_mod.RepoContext) = .empty,
    watcher: ?watcher_mod.Watcher = null,
    debug_tool_tier: ToolTier = .specialist,
    /// Client info from MCP initialize request (agent name, version, model).
    client_agent_name: ?[]const u8 = null,
    client_agent_version: ?[]const u8 = null,
    client_model: ?[]const u8 = null,
    /// Update notice staged by UpdateCheckState, consumed once by the next
    /// code tool result. Its own mutex: handler threads take it while the
    /// main runtime mutex may be held for long index operations.
    pending_update_notice: ?PendingUpdateNotice = null,
    update_notice_mutex: std.Thread.Mutex = .{},
    /// Protects code_cache, remote_tools, mcp_session_id, and mem_db from concurrent access.
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator, debug_tool_tier: ToolTier) !Runtime {
        const brain = config_mod.resolveBrain(allocator);
        errdefer brain.deinit(allocator);
        const observe_enabled = settings_mod.isObserveEnabled(allocator);
        debug_log_mod.log("Runtime.init: brain_type={s} observe_enabled={any}", .{ @tagName(brain), observe_enabled });
        return .{
            .allocator = allocator,
            .mem_config = switch (brain) {
                .remote => |r| r,
                else => null,
            },
            .brain_type = brain,
            .mem_db = null,
            .debug_server = DebugServer.init(allocator),
            .observe_enabled = observe_enabled,
            .observe_server = if (observe_enabled) try ObserveServer.init(allocator) else null,
            .code_cache = null,
            .code_cache_generation = null,
            .remote_tools = null,
            .mcp_session_id = null,
            .session_contexts = .empty,
            .remote_memory_capabilities = .{},
            .repo_context_cache = .empty,
            .watcher = watcher_mod.Watcher.init(allocator),
            .debug_tool_tier = debug_tool_tier,
        };
    }

    fn deinit(self: *Runtime) void {
        if (self.watcher) |*w| w.deinit();
        if (self.mem_db) |*mdb| mdb.close();
        // brain_type owns the Config when .remote — don't also free via mem_config
        self.brain_type.deinit(self.allocator);
        if (self.code_cache) |*ci| ci.deinit(self.allocator);
        if (self.remote_tools) |tools| freeRemoteToolSlice(self.allocator, tools);
        self.remote_memory_capabilities.deinit(self.allocator);
        var session_iter = self.session_contexts.iterator();
        while (session_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.session_contexts.deinit(self.allocator);
        var repo_iter = self.repo_context_cache.iterator();
        while (repo_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.repo_context_cache.deinit(self.allocator);
        if (self.mcp_session_id) |sid| self.allocator.free(sid);
        if (self.pending_update_notice) |notice| {
            self.allocator.free(notice.line);
            self.allocator.free(notice.latest);
        }
        if (self.client_agent_name) |v| self.allocator.free(v);
        if (self.client_agent_version) |v| self.allocator.free(v);
        if (self.client_model) |v| self.allocator.free(v);
        self.debug_server.deinit();
        if (self.observe_server) |*server| server.deinit();
    }

    fn setPendingUpdateNotice(self: *Runtime, notice: PendingUpdateNotice) void {
        self.update_notice_mutex.lock();
        defer self.update_notice_mutex.unlock();
        if (self.pending_update_notice) |old| {
            self.allocator.free(old.line);
            self.allocator.free(old.latest);
        }
        self.pending_update_notice = notice;
    }

    /// Take-and-clear so the notice is delivered exactly once per session
    /// even with concurrent handler threads.
    fn takePendingUpdateNotice(self: *Runtime) ?PendingUpdateNotice {
        self.update_notice_mutex.lock();
        defer self.update_notice_mutex.unlock();
        const notice = self.pending_update_notice orelse return null;
        self.pending_update_notice = null;
        return notice;
    }

    fn hasMemory(self: *const Runtime) bool {
        return self.brain_type != .none;
    }

    fn isLocalBrain(self: *const Runtime) bool {
        return self.brain_type == .local;
    }

    fn ensureMemoryDb(self: *Runtime) !*memory_mod.MemoryDb {
        if (self.mem_db != null) return &self.mem_db.?;
        const local = switch (self.brain_type) {
            .local => |l| l,
            else => return error.NotConfigured,
        };
        debug_log_mod.log("Runtime: lazy-opening local brain at {s}", .{local.path});
        // Convert path to null-terminated
        const path_z = try self.allocator.dupeZ(u8, local.path);
        defer self.allocator.free(path_z);
        self.mem_db = try memory_mod.MemoryDb.open(self.allocator, path_z, local.brain_id);
        return &self.mem_db.?;
    }

    fn indexGeneration(self: *Runtime) ?IndexGeneration {
        const cog_dir = paths.findCogDir(self.allocator) catch {
            debug_log_mod.log("mcp.cache: index generation unavailable; no .cog directory", .{});
            return null;
        };
        defer self.allocator.free(cog_dir);
        const index_path = std.fmt.allocPrint(self.allocator, "{s}/index.scip", .{cog_dir}) catch return null;
        defer self.allocator.free(index_path);
        const file = std.fs.openFileAbsolute(index_path, .{}) catch |err| {
            debug_log_mod.log("mcp.cache: index generation open failed error={s}", .{@errorName(err)});
            return null;
        };
        defer file.close();
        const stat = file.stat() catch |err| {
            debug_log_mod.log("mcp.cache: index generation stat failed error={s}", .{@errorName(err)});
            return null;
        };
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime };
    }

    fn ensureCodeCache(self: *Runtime) !*code_intel.CodeIndex {
        const disk_generation = self.indexGeneration();
        if (self.code_cache != null) {
            if (disk_generation != null and self.code_cache_generation != null and self.code_cache_generation.?.eql(disk_generation.?)) {
                debug_log_mod.log("mcp.cache: generation unchanged inode={d} size={d}", .{ disk_generation.?.inode, disk_generation.?.size });
                return &self.code_cache.?;
            }
            debug_log_mod.log("mcp.cache: generation changed or unavailable; refreshing", .{});
        }

        const fresh = code_intel.loadIndexForRuntime(self.allocator) catch |err| {
            debug_log_mod.log("mcp.cache: refresh failed error={s}; invalidating stale cache", .{@errorName(err)});
            self.invalidateCodeCache();
            return err;
        };
        const fresh_generation = self.indexGeneration() orelse {
            var discarded = fresh;
            discarded.deinit(self.allocator);
            self.invalidateCodeCache();
            return error.IndexUnavailable;
        };
        if (disk_generation) |before| {
            if (!before.eql(fresh_generation)) {
                debug_log_mod.log("mcp.cache: generation changed during load; retrying once", .{});
                var discarded = fresh;
                discarded.deinit(self.allocator);
                const retry = code_intel.loadIndexForRuntime(self.allocator) catch |err| {
                    self.invalidateCodeCache();
                    return err;
                };
                const retry_generation = self.indexGeneration() orelse {
                    var retry_discarded = retry;
                    retry_discarded.deinit(self.allocator);
                    self.invalidateCodeCache();
                    return error.IndexUnavailable;
                };
                if (self.code_cache) |*old| old.deinit(self.allocator);
                self.code_cache = retry;
                self.code_cache_generation = retry_generation;
                debug_log_mod.log("mcp.cache: retry refreshed inode={d} size={d} mtime={d}", .{ retry_generation.inode, retry_generation.size, retry_generation.mtime });
                return &self.code_cache.?;
            }
        }
        if (self.code_cache) |*old| old.deinit(self.allocator);
        self.code_cache = fresh;
        self.code_cache_generation = fresh_generation;
        debug_log_mod.log("mcp.cache: atomically refreshed inode={d} size={d} mtime={d}", .{ fresh_generation.inode, fresh_generation.size, fresh_generation.mtime });
        return &self.code_cache.?;
    }

    fn invalidateCodeCache(self: *Runtime) void {
        if (self.code_cache) |*ci| {
            debug_log_mod.log("mcp.cache: invalidating loaded index", .{});
            ci.deinit(self.allocator);
            self.code_cache = null;
        }
        self.code_cache_generation = null;
    }

    fn refreshCodeCache(self: *Runtime) !void {
        self.invalidateCodeCache();
        _ = try self.ensureCodeCache();
    }

    fn syncCodeCacheAfterWrite(self: *Runtime) !void {
        _ = try self.ensureCodeCache();
    }

    fn currentSessionKey(self: *const Runtime) []const u8 {
        return self.mcp_session_id orelse "local-stdio-session";
    }

    fn ensureSessionContext(self: *Runtime) !*session_context_mod.SessionContext {
        const key = self.currentSessionKey();
        if (self.session_contexts.getPtr(key)) |ctx| return ctx;

        const repo_ctx = try self.resolveRepoContext();
        const workspace_root = try resolveWorkspaceRoot(self.allocator, repo_ctx.cwd);
        defer self.allocator.free(workspace_root);
        const host_agent_id = try detectHostAgentId(self.allocator, workspace_root);
        defer self.allocator.free(host_agent_id);

        const brain_url = if (self.mem_config) |cfg| cfg.brain_url else "file:.cog/brain.db";
        const brain_parts = parseBrainIdentity(brain_url);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const ctx = try session_context_mod.initSessionContext(
            self.allocator,
            key,
            host_agent_id,
            self.client_agent_version,
            self.client_model,
            workspace_root,
            brain_url,
            if (brain_parts) |parts| parts.namespace else null,
            if (brain_parts) |parts| parts.name else null,
            repo_ctx,
        );
        try self.session_contexts.put(self.allocator, owned_key, ctx);
        debug_log_mod.log("mcp.ensureSessionContext: created session={s}", .{key});
        return self.session_contexts.getPtr(key).?;
    }

    fn resolveRepoContext(self: *Runtime) !*repo_context_mod.RepoContext {
        const cwd = try std.fs.cwd().realpathAlloc(self.allocator, ".");
        defer self.allocator.free(cwd);

        if (self.repo_context_cache.getPtr(cwd)) |cached| return cached;
        const resolved = try repo_context_mod.resolve(self.allocator, cwd);
        const key = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(key);
        try self.repo_context_cache.put(self.allocator, key, resolved);
        debug_log_mod.log("mcp.resolveRepoContext: cached cwd={s}", .{cwd});
        return self.repo_context_cache.getPtr(cwd).?;
    }
};

pub fn serve(allocator: std.mem.Allocator, version: []const u8, args: []const [:0]const u8) !void {
    server_version = version;
    shutdown_requested.store(false, .release);

    // Parse MCP-specific CLI flags
    var debug_tool_tier: ToolTier = .specialist; // default: expose all tools
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug-tools=")) {
            const val = arg["--debug-tools=".len..];
            if (std.mem.eql(u8, val, "core")) {
                debug_tool_tier = .core;
            } else if (std.mem.eql(u8, val, "extended")) {
                debug_tool_tier = .extended;
            } else if (std.mem.eql(u8, val, "all")) {
                debug_tool_tier = .specialist;
            }
        }
    }

    // On macOS, ensure debug entitlements are active for task_for_pid().
    // Sign the binary and re-exec so the kernel grants the entitlement.
    // execvpe preserves the same PID and stdio file descriptors, so the
    // MCP client's pipe is unaffected.
    if (builtin.os.tag == .macos) {
        if (std.posix.getenv("COG_DEBUG_SIGNED") == null) {
            debug_mod.ensureDebugEntitlements(allocator) catch {};
            debug_mod.reexecWithEntitlements();
            // If re-exec failed, continue without entitlements
        }
    }

    debug_log_mod.log("mcp.serve: starting version={s} debug_tools={s}", .{ version, @tagName(debug_tool_tier) });
    setupSignalHandler();

    var runtime = try Runtime.init(allocator, debug_tool_tier);
    // Start the watcher thread AFTER runtime is in its final stack location.
    // The thread captures a pointer to runtime.watcher, so it must not move.
    if (runtime.watcher != null) {
        runtime.watcher.?.start();
        debug_log_mod.log("File watcher started", .{});
    }
    debug_log_mod.log("Runtime initialized, mem_config={s}, entering main loop", .{if (runtime.mem_config != null) "present" else "null"});

    const stdin = std.fs.File.stdin();

    // Thread-safe stdout writer shared by all handler threads
    var stdout_mutex: std.Thread.Mutex = .{};
    const stdout_writer = StdoutWriter{
        .file = std.fs.File.stdout(),
        .mutex = &stdout_mutex,
    };

    var handler_threads = HandlerThreads.init(MAX_HANDLER_CONCURRENCY);
    var handler_threads_drained = false;
    defer {
        if (!drainHandlerThreads(&handler_threads, &handler_threads_drained)) {
            // An error path must not unwind stack-owned runtime state while a
            // timed-out worker can still access it.
            debug_log_mod.log("mcp.serve: error cleanup deadline reached; exiting without stack unwind", .{});
            std.process.exit(1);
        }
    }
    debug_log_mod.log("mcp.handlers: initialized concurrency limit={d}", .{MAX_HANDLER_CONCURRENCY});

    var input_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer input_buf.deinit(allocator);
    var framing_state: MessageFramingState = .{};

    var read_buf: [8192]u8 = undefined;
    var watcher_batch: watcher_mod.BatchState = .{};
    var watcher_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (watcher_paths.items) |file_path| allocator.free(file_path);
        watcher_paths.deinit(allocator);
    }
    var watcher_overflow = false;

    // Reconcile whatever changed while no server was running before trusting
    // the on-disk index; the flag keeps code tools honest meanwhile.
    var index_sync: IndexSyncState = .{};
    defer index_sync.deinit(allocator);
    index_sync.spawn(&runtime, "startup", std.time.nanoTimestamp());

    // Throttled release check: one detached worker per session; a due notice
    // rides along with the next code tool result. An in-flight worker at
    // shutdown finishes on its own, exactly like the reconcile worker.
    var update_state: UpdateCheckState = .{};
    update_state.spawn(&runtime);

    while (!shutdown_requested.load(.acquire)) {
        if (builtin.os.tag != .windows) {
            var fds: [2]posix.pollfd = undefined;
            fds[0] = .{ .fd = stdin.handle, .events = posix.POLL.IN, .revents = 0 };
            var nfds: usize = 1;
            if (runtime.watcher) |*w| {
                fds[1] = .{ .fd = w.getFd(), .events = posix.POLL.IN, .revents = 0 };
                nfds = 2;
            }
            const poll_result = posix.poll(fds[0..nfds], watcher_poll_interval_ms) catch continue;
            const now_ns = std.time.nanoTimestamp();

            if (nfds > 1 and fds[1].revents & posix.POLL.IN != 0) {
                const drained = collectWatcherEvents(&runtime, &watcher_paths, &watcher_overflow);
                if (drained > 0 or watcher_overflow) {
                    watcher_batch.pending_count += @max(drained, @as(usize, 1));
                    watcher_batch.last_event_ns = now_ns;
                    debug_log_mod.log("watcher batch: pending={d} paths={d} overflow={any}", .{ watcher_batch.pending_count, watcher_paths.items.len, watcher_overflow });
                }
            }
            if (watcher_batch.shouldFlush(now_ns)) {
                debug_log_mod.log("watcher batch: flushing pending={d}", .{watcher_batch.pending_count});
                processWatcherEvents(&runtime, &watcher_paths, watcher_overflow, &index_sync);
                watcher_batch.reset();
                watcher_overflow = false;
            }
            index_sync.tick(&runtime, now_ns);
            update_state.tick(&runtime);
            if (poll_result == 0) continue;

            if (fds[0].revents & posix.POLL.ERR != 0) {
                debug_log_mod.log("poll: POLLERR on stdin, exiting", .{});
                break;
            }
            if (fds[0].revents & posix.POLL.IN == 0) {
                // If stdin is hung up and there's no readable data left,
                // terminate the server loop.
                if (fds[0].revents & posix.POLL.HUP != 0) {
                    debug_log_mod.log("poll: POLLHUP on stdin, exiting", .{});
                    break;
                }
                continue;
            }
        }

        const n = stdin.read(&read_buf) catch |err| {
            debug_log_mod.log("stdin read error: {s}", .{@errorName(err)});
            break;
        };
        if (n == 0) {
            debug_log_mod.log("stdin EOF (read returned 0)", .{});
            break;
        }
        debug_log_mod.log("Read {d} bytes from stdin", .{n});
        if (std.mem.indexOfScalar(u8, read_buf[0..n], 0x03) != null) {
            shutdown_requested.store(true, .release);
            break;
        }
        // A framing failure must not unwind past the handler drain below:
        // in-flight handler threads still reference stack-owned runtime state.
        appendFramingInput(allocator, &input_buf, &framing_state, read_buf[0..n]) catch |err| {
            debug_log_mod.log("mcp.framing: input buffering failed: {s}; beginning shutdown", .{@errorName(err)});
            shutdown_requested.store(true, .release);
            break;
        };

        while (!shutdown_requested.load(.acquire)) {
            const framed = (nextMessageFromBuffer(allocator, &input_buf, &framing_state) catch |err| {
                debug_log_mod.log("mcp.framing: message extraction failed: {s}; beginning shutdown", .{@errorName(err)});
                shutdown_requested.store(true, .release);
                break;
            }) orelse break;
            switch (framed) {
                .oversized_complete, .oversized_partial => {
                    debug_log_mod.log("mcp.framing: rejecting oversized message with null id", .{});
                    writeError(allocator, null, -32600, "Invalid Request", stdout_writer) catch |err| {
                        logErr("MCP oversized response error: ", err);
                        if (err == error.WriteFailure) {
                            shutdown_requested.store(true, .release);
                            break;
                        }
                    };
                },
                .message => |msg| {
                    const slot_index = handler_threads.begin() orelse {
                        debug_log_mod.log("mcp.handlers: dropping buffered request after shutdown", .{});
                        allocator.free(msg);
                        break;
                    };
                    if (shutdown_requested.load(.acquire)) {
                        debug_log_mod.log("mcp.handlers: shutdown observed after slot reservation; rejecting request", .{});
                        handler_threads.cancel(slot_index);
                        allocator.free(msg);
                        break;
                    }

                    // The thread owns `msg`; HandlerThreads owns and joins the thread.
                    const thread = std.Thread.spawn(.{}, handleRequest, .{ &runtime, msg, stdout_writer, &handler_threads, slot_index }) catch |err| {
                        handler_threads.cancel(slot_index);
                        debug_log_mod.log("mcp.handlers: spawn failed error={s}; processing inline", .{@errorName(err)});
                        defer allocator.free(msg);
                        processMessage(&runtime, msg, stdout_writer) catch |process_err| {
                            logErr("MCP processMessage error: ", process_err);
                            if (process_err == error.WriteFailure) {
                                shutdown_requested.store(true, .release);
                                break;
                            }
                        };
                        continue;
                    };
                    handler_threads.track(slot_index, thread);
                },
            }
        }
    }

    if (!deinitRuntimeAfterHandlerDrain(&handler_threads, &handler_threads_drained, &runtime)) {
        // Stack-owned runtime state must remain alive while hung workers may still
        // reference it. Skip all stack unwinding and let process exit reclaim it.
        debug_log_mod.log("mcp.serve: handler shutdown deadline reached; exiting without runtime teardown", .{});
        std.process.exit(0);
    }

    // Force-exit after the full Runtime teardown. On macOS the file-watcher
    // thread can get stuck in CFRunLoop's mach_msg2_trap, making a final
    // process-level thread join hang indefinitely and leave an orphan.
    std.process.exit(0);
}

fn deinitRuntimeAfterHandlerDrain(handler_threads: *HandlerThreads, drained: *bool, runtime: anytype) bool {
    return deinitRuntimeAfterHandlerDrainWithin(handler_threads, drained, runtime, handler_shutdown_grace_ns);
}

fn deinitRuntimeAfterHandlerDrainWithin(
    handler_threads: *HandlerThreads,
    drained: *bool,
    runtime: anytype,
    timeout_ns: u64,
) bool {
    debug_log_mod.log("mcp.serve: shutdown requested; stopping handler intake before runtime teardown", .{});
    handler_threads.stopAccepting();
    if (!drainHandlerThreadsWithin(handler_threads, drained, timeout_ns)) return false;

    debug_log_mod.log("mcp.serve: deinitializing full runtime after handler drain", .{});
    runtime.deinit();
    debug_log_mod.log("mcp.serve: full runtime deinitialized", .{});
    return true;
}

fn drainHandlerThreads(handler_threads: *HandlerThreads, drained: *bool) bool {
    if (drained.*) return true;
    debug_log_mod.log("mcp.serve: shutdown requested; stopping handler intake", .{});
    handler_threads.stopAccepting();
    return drainHandlerThreadsWithin(handler_threads, drained, handler_shutdown_grace_ns);
}

// Returns false instead of exiting so helper and library tests can validate the
// deadline policy without terminating their process. serve() owns the exit
// decision because only it knows stack-owned Runtime must remain live.
fn drainHandlerThreadsWithin(handler_threads: *HandlerThreads, drained: *bool, timeout_ns: u64) bool {
    if (drained.*) return true;
    return switch (handler_threads.drain(timeout_ns)) {
        .complete => {
            drained.* = true;
            debug_log_mod.log("mcp.serve: handlers drained before runtime teardown", .{});
            return true;
        },
        .timed_out => {
            debug_log_mod.log("mcp.serve: handlers still active at shutdown deadline", .{});
            return false;
        },
    };
}

fn setupSignalHandler() void {
    if (builtin.os.tag == .windows) return;

    const act: posix.Sigaction = .{
        .handler = .{ .handler = sigHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);

    // Ignore SIGPIPE so that writes to a closed stdout return
    // error.BrokenPipe instead of killing the process.
    const ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null);
}

fn sigHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn drainConsumed(allocator: std.mem.Allocator, input: *std.ArrayListUnmanaged(u8), consumed: usize) !void {
    if (consumed == 0) return;
    if (consumed >= input.items.len) {
        input.clearRetainingCapacity();
        return;
    }
    const remain = input.items.len - consumed;
    std.mem.copyForwards(u8, input.items[0..remain], input.items[consumed..]);
    input.shrinkRetainingCapacity(remain);
    _ = allocator;
}

/// Maximum byte length accepted for one inbound newline-delimited JSON frame.
/// Frames above this transport contract are rejected before JSON-RPC dispatch.
pub const max_transport_frame_bytes: usize = 4 * 1024 * 1024;

/// Stable human-readable rendering of `max_transport_frame_bytes` for CLI/docs.
pub const max_transport_frame_size_label = "4 MiB (4,194,304 bytes)";

const BufferedMessage = union(enum) {
    message: []u8,
    oversized_complete,
    oversized_partial,
};

const MessageFramingState = struct {
    discarding_oversized: bool = false,
};

fn appendFramingInput(
    allocator: std.mem.Allocator,
    input: *std.ArrayListUnmanaged(u8),
    state: *MessageFramingState,
    bytes: []const u8,
) !void {
    var remaining = bytes;
    if (state.discarding_oversized) {
        if (std.mem.indexOfScalar(u8, remaining, '\n')) |pos| {
            debug_log_mod.log("mcp.framing: discarded oversized tail bytes={d}, resynchronized", .{pos + 1});
            state.discarding_oversized = false;
            remaining = remaining[pos + 1 ..];
        } else {
            debug_log_mod.log("mcp.framing: discarding oversized tail bytes={d}", .{remaining.len});
            return;
        }
    }

    if (remaining.len > 0) try input.appendSlice(allocator, remaining);
}

fn nextMessageFromBuffer(
    allocator: std.mem.Allocator,
    input: *std.ArrayListUnmanaged(u8),
    state: *MessageFramingState,
) !?BufferedMessage {
    // MCP stdio transport: messages are newline-delimited JSON.
    // Each message is a single JSON object on one line, terminated by \n.
    const bytes = input.items;
    if (bytes.len == 0) return null;

    // Skip any leading whitespace/newlines between messages.
    var start: usize = 0;
    while (start < bytes.len and (bytes[start] == '\n' or bytes[start] == '\r' or bytes[start] == ' ' or bytes[start] == '\t')) {
        start += 1;
    }
    if (start > 0) {
        try drainConsumed(allocator, input, start);
        if (input.items.len == 0) return null;
    }

    // Find the newline that terminates this JSON message.
    const newline_pos = std.mem.indexOfScalar(u8, input.items, '\n');
    if (newline_pos) |pos| {
        if (pos > max_transport_frame_bytes) {
            debug_log_mod.log("mcp.framing: oversized complete message bytes={d}, limit={d}", .{ pos, max_transport_frame_bytes });
            try drainConsumed(allocator, input, pos + 1);
            return .oversized_complete;
        }
        const msg = try allocator.dupe(u8, input.items[0..pos]);
        try drainConsumed(allocator, input, pos + 1);
        return .{ .message = msg };
    }

    // No newline yet — check if the buffer contains a complete JSON object.
    // Some clients send JSON without a trailing newline (e.g. as last message
    // before closing stdin). Try to parse what we have. Bound the scan to one
    // byte past the limit so an incomplete oversized frame is rejected promptly.
    if (input.items.len > 0 and input.items[0] == '{') {
        // Validate it's complete JSON by counting braces.
        var depth: usize = 0;
        var in_string = false;
        var escape = false;
        const scan_len = @min(input.items.len, max_transport_frame_bytes + 1);
        for (input.items[0..scan_len], 0..) |c, i| {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\' and in_string) {
                escape = true;
                continue;
            }
            if (c == '"' and !escape) {
                in_string = !in_string;
                continue;
            }
            if (!in_string) {
                if (c == '{') depth += 1;
                if (c == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        const end = i + 1;
                        if (end > max_transport_frame_bytes) {
                            debug_log_mod.log("mcp.framing: oversized complete brace-framed message bytes={d}, limit={d}", .{ end, max_transport_frame_bytes });
                            try drainConsumed(allocator, input, end);
                            return .oversized_complete;
                        }
                        const msg = try allocator.dupe(u8, input.items[0..end]);
                        try drainConsumed(allocator, input, end);
                        return .{ .message = msg };
                    }
                }
            }
        }
    }

    if (input.items.len > max_transport_frame_bytes) {
        debug_log_mod.log("mcp.framing: oversized partial message buffered={d}, limit={d}; discarding until newline", .{ input.items.len, max_transport_frame_bytes });
        input.clearRetainingCapacity();
        state.discarding_oversized = true;
        return .oversized_partial;
    }

    // Incomplete message — wait for more data.
    return null;
}

/// Handler thread entry point. Owns `msg` and frees it when done.
fn handleRequest(runtime: *Runtime, msg: []const u8, stdout: StdoutWriter, handlers: *HandlerThreads, slot_index: usize) void {
    defer handlers.finish(slot_index);
    defer runtime.allocator.free(msg);
    processMessage(runtime, msg, stdout) catch |err| {
        logErr("MCP processMessage error: ", err);
        if (err == error.WriteFailure) {
            shutdown_requested.store(true, .release);
        }
    };
}

fn processMessage(runtime: *Runtime, line: []const u8, stdout: StdoutWriter) !void {
    const allocator = runtime.allocator;

    const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
        debug_log_mod.log("Parse error on incoming message", .{});
        try writeError(allocator, null, -32700, "Parse error", stdout);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try writeError(allocator, null, -32600, "Invalid Request", stdout);
        return;
    }

    const method_val = root.object.get("method") orelse {
        try writeError(allocator, null, -32600, "Missing method", stdout);
        return;
    };
    if (method_val != .string) {
        try writeError(allocator, null, -32600, "Method must be string", stdout);
        return;
    }
    const method = method_val.string;
    debug_log_mod.log("Method: {s}", .{method});

    // Get request id (may be null for notifications)
    const id = root.object.get("id");

    // For requests (id != null), create a ReplyOnce guard that guarantees
    // exactly one response is sent. If the handler returns without responding,
    // the guard's deinit sends a fallback internal error.
    var reply = ReplyOnce.init(allocator, id, stdout);
    defer reply.deinit();

    // Dispatch
    if (std.mem.eql(u8, method, "initialize")) {
        const params = root.object.get("params");
        handleInitialize(runtime, &reply, params) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        reply.markNotification(); // No response needed
    } else if (std.mem.eql(u8, method, "shutdown")) {
        handleShutdown(allocator, &reply) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "exit")) {
        reply.markNotification(); // No response needed
        shutdown_requested.store(true, .release);
    } else if (std.mem.eql(u8, method, "ping")) {
        handlePing(allocator, &reply) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "tools/list")) {
        handleToolsList(runtime, &reply) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.object.get("params");
        handleToolsCall(runtime, &reply, params) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "resources/list")) {
        handleResourcesList(allocator, &reply) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "resources/read")) {
        const params = root.object.get("params");
        handleResourcesRead(runtime, &reply, params) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        handlePromptsList(allocator, &reply) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        const params = root.object.get("params");
        handlePromptsGet(allocator, &reply, params) catch |err| {
            try handleDispatchError(&reply, err);
        };
    } else if (std.mem.eql(u8, method, "notifications/cancelled") or std.mem.eql(u8, method, "notifications/progress")) {
        reply.markNotification(); // No response needed
    } else {
        if (id != null) {
            debug_log_mod.log("mcp.dispatch: unknown method={s}; sending method-not-found error", .{method});
            try reply.sendError(-32601, "Method not found");
        } else {
            reply.markNotification();
        }
    }
}

// ── Stdout Writer ───────────────────────────────────────────────────────
//
// Thread-safe wrapper around stdout that serializes all JSON-RPC response
// writes through a mutex. Shared across all handler threads.

const StdoutWriter = struct {
    file: std.fs.File,
    mutex: *std.Thread.Mutex,

    fn writeResponse(self: StdoutWriter, data: []const u8) !void {
        debug_log_mod.log("stdout_writer: acquiring mutex", .{});
        self.mutex.lock();
        defer {
            self.mutex.unlock();
            debug_log_mod.log("stdout_writer: mutex released", .{});
        }
        debug_log_mod.log("stdout_writer: mutex acquired", .{});
        var buf: [8192]u8 = undefined;
        var w = self.file.writerStreaming(&buf);
        w.interface.writeAll(data) catch return error.WriteFailure;
        w.interface.writeAll("\n") catch return error.WriteFailure;
        w.interface.flush() catch return error.WriteFailure;
    }
};

// ── ReplyOnce Guard ─────────────────────────────────────────────────────
//
// Guarantees that every MCP request receives exactly one JSON-RPC response.
// Create one per request, use `defer reply.deinit()`. If no response has been
// sent when deinit runs, a fallback -32603 "Internal error" is emitted.
// For notifications (no id), call `markNotification()` to suppress the guard.

const ReplyOnce = struct {
    allocator: std.mem.Allocator,
    id: ?json.Value,
    stdout: StdoutWriter,
    responded: bool = false,
    is_notification: bool = false,

    fn init(allocator: std.mem.Allocator, id: ?json.Value, stdout: StdoutWriter) ReplyOnce {
        return .{
            .allocator = allocator,
            .id = id,
            .stdout = stdout,
        };
    }

    /// Mark this message as a notification (no response expected).
    fn markNotification(self: *ReplyOnce) void {
        self.is_notification = true;
    }

    /// Send a successful tool result. Sets responded = true.
    fn sendToolResult(self: *ReplyOnce, content: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try writeToolResult(self.allocator, self.id, content, self.stdout);
    }

    /// Send a tool-level error (isError=true in MCP result). Sets responded = true.
    fn sendToolError(self: *ReplyOnce, message: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try writeToolError(self.allocator, self.id, message, self.stdout);
    }

    /// Send a JSON-RPC error response. Sets responded = true.
    fn sendError(self: *ReplyOnce, code: i32, message: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try writeError(self.allocator, self.id, code, message, self.stdout);
    }

    /// Send a pre-formatted raw JSON response. Sets responded = true.
    fn sendRaw(self: *ReplyOnce, data: []const u8) !void {
        if (self.responded) return;
        self.responded = true;
        try self.stdout.writeResponse(data);
    }

    /// Send a -32603 internal error. Used by catch blocks in processMessage.
    fn sendInternalError(self: *ReplyOnce, err: anyerror) !void {
        if (self.responded) return;
        if (self.id == null) return;
        debug_log_mod.log("Handler error: {s}, sending internal error response", .{@errorName(err)});
        self.responded = true;
        try writeError(self.allocator, self.id, -32603, "Internal error", self.stdout);
    }

    /// Destructor — the safety net. If no response was sent for a request,
    /// emit a fallback internal error so the client never hangs.
    fn deinit(self: *ReplyOnce) void {
        if (self.is_notification) return;
        if (self.responded) return;
        if (self.id == null) return;
        debug_log_mod.log("ReplyOnce: handler returned without responding, sending fallback error", .{});
        writeError(self.allocator, self.id, -32603, "Internal error: no response produced", self.stdout) catch {};
    }
};

fn handleDispatchError(reply: *ReplyOnce, err: anyerror) !void {
    if (err == error.WriteFailure) return err;
    try reply.sendInternalError(err);
}

fn handleShutdown(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    shutdown_requested.store(true, .release);
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handlePing(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleInitialize(runtime: *Runtime, reply: *ReplyOnce, params: ?json.Value) !void {
    const allocator = runtime.allocator;

    // Extract clientInfo from params (agent name, version, model)
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("clientInfo")) |ci| {
                if (ci == .object) {
                    if (ci.object.get("name")) |n| {
                        if (n == .string) {
                            if (runtime.client_agent_name) |old| allocator.free(old);
                            runtime.client_agent_name = allocator.dupe(u8, n.string) catch null;
                        }
                    }
                    if (ci.object.get("version")) |v| {
                        if (v == .string) {
                            if (runtime.client_agent_version) |old| allocator.free(old);
                            runtime.client_agent_version = allocator.dupe(u8, v.string) catch null;
                        }
                    }
                    // Extension: some agents may report model in clientInfo
                    if (ci.object.get("model")) |m| {
                        if (m == .string) {
                            if (runtime.client_model) |old| allocator.free(old);
                            runtime.client_model = allocator.dupe(u8, m.string) catch null;
                        }
                    }
                }
            }
            // Also check _meta.model as an extension field
            if (runtime.client_model == null) {
                if (p.object.get("_meta")) |meta| {
                    if (meta == .object) {
                        if (meta.object.get("model")) |m| {
                            if (m == .string) {
                                runtime.client_model = allocator.dupe(u8, m.string) catch null;
                            }
                        }
                    }
                }
            }
        }
    }

    // Append client info to the log header (completes the header block)
    debug_log_mod.logClientInfo(
        runtime.client_agent_name,
        runtime.client_agent_version,
        runtime.client_model,
    );

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("protocolVersion");
    try s.write("2025-11-25");
    try s.objectField("capabilities");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginObject();
    try s.endObject();
    try s.objectField("prompts");
    try s.beginObject();
    try s.endObject();
    try s.objectField("resources");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.objectField("serverInfo");
    try s.beginObject();
    try s.objectField("name");
    try s.write("cog");
    try s.objectField("version");
    try s.write(server_version);
    try s.endObject();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleToolsList(runtime: *Runtime, reply: *ReplyOnce) !void {
    const allocator = runtime.allocator;

    // Protect remote_tools discovery/access
    debug_log_mod.log("handleToolsList: acquiring runtime mutex", .{});
    runtime.mutex.lock();
    defer {
        runtime.mutex.unlock();
        debug_log_mod.log("handleToolsList: runtime mutex released", .{});
    }
    debug_log_mod.log("handleToolsList: runtime mutex acquired", .{});

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    try writeToolCatalog(runtime, allocator, &s);

    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleToolsCall(runtime: *Runtime, reply: *ReplyOnce, params: ?json.Value) !void {
    const allocator = runtime.allocator;
    const p = params orelse {
        try reply.sendError(-32602, "Missing params");
        return;
    };
    if (p != .object) {
        try reply.sendError(-32602, "Invalid params");
        return;
    }

    const name_val = p.object.get("name") orelse {
        try reply.sendError(-32602, "Missing tool name");
        return;
    };
    if (name_val != .string) {
        try reply.sendError(-32602, "Tool name must be string");
        return;
    }
    const tool_name = name_val.string;
    debug_log_mod.log("handleToolsCall: {s}", .{tool_name});

    const arguments = if (p.object.get("arguments")) |a| (if (a == .object) a else null) else null;

    debug_log_mod.log("handleToolsCall: acquiring runtime mutex for session context ({s})", .{tool_name});
    runtime.mutex.lock();
    debug_log_mod.log("handleToolsCall: runtime mutex acquired for session context ({s})", .{tool_name});
    _ = runtime.ensureSessionContext() catch {};
    runtime.mutex.unlock();
    debug_log_mod.log("handleToolsCall: runtime mutex released for session context ({s})", .{tool_name});

    // Dispatch tool
    const tool_result = runtimeCallTool(runtime, tool_name, arguments) catch |err| {
        const err_msg = switch (err) {
            error.MissingName => "Missing required parameter: name. Check the tool schema for required fields.",
            error.MissingFile => "Missing required parameter: file. Provide a file path for this query.",
            error.NotConfigured => "Memory not configured. Proceed without memory for now. The user can run 'cog init' to enable it.",
            error.IndexUnavailable => "Code index unavailable. Run 'cog code:index' in a terminal to build it, or use Read and Glob for file-based exploration.",
            error.ObserveDisabled => settings_mod.OBSERVE_DISABLED_MESSAGE,
            error.ToolUnavailable => "Unknown or unavailable tool. Refresh tools/list and call only an advertised capability.",
            error.Explained => "Operation failed. Try once more or use an alternative approach.",
            else => "Internal error. Try the operation once more. If it fails again, use an alternative approach.",
        };
        try reply.sendToolError(err_msg);
        return;
    };
    defer allocator.free(tool_result);

    try reply.sendToolResult(tool_result);
}

fn handlePromptsList(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("prompts");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("name");
    try s.write("cog_reference");
    try s.objectField("description");
    try s.write("Reference for predicates, staleness checks, and consolidation guidance");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handlePromptsGet(allocator: std.mem.Allocator, reply: *ReplyOnce, params: ?json.Value) !void {
    const p = params orelse {
        try reply.sendError(-32602, "Missing params");
        return;
    };
    if (p != .object) {
        try reply.sendError(-32602, "Invalid params");
        return;
    }
    const name_val = p.object.get("name") orelse {
        try reply.sendError(-32602, "Missing prompt name");
        return;
    };
    if (name_val != .string) {
        try reply.sendError(-32602, "Prompt name must be string");
        return;
    }

    if (!std.mem.eql(u8, name_val.string, "cog_reference")) {
        try reply.sendError(-32602, "Unknown prompt");
        return;
    }

    const prompt_text =
        "Use concise, specific terms and explicit predicates when recording memory. " ++
        "Prefer chain relationships for causality and dependency, and use associations for hub concepts. " ++
        "Validate stale links periodically; reinforce validated memories and flush invalid short-term memories during consolidation.";

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("description");
    try s.write("Cog memory reference guidance");
    try s.objectField("messages");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("role");
    try s.write("assistant");
    try s.objectField("content");
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(prompt_text);
    try s.endObject();
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleResourcesList(allocator: std.mem.Allocator, reply: *ReplyOnce) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("resources");
    try s.beginArray();

    try s.beginObject();
    try s.objectField("uri");
    try s.write("cog://debug/tools");
    try s.objectField("name");
    try s.write("Debug Tool Catalog");
    try s.objectField("description");
    try s.write("All debug_* MCP tools exposed by Cog");
    try s.objectField("mimeType");
    try s.write("application/json");
    try s.endObject();

    try s.beginObject();
    try s.objectField("uri");
    try s.write("cog://tools/catalog");
    try s.objectField("name");
    try s.write("MCP Tool Catalog");
    try s.objectField("description");
    try s.write("All MCP tools currently exposed by this Cog runtime");
    try s.objectField("mimeType");
    try s.write("application/json");
    try s.endObject();

    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn handleResourcesRead(runtime: *Runtime, reply: *ReplyOnce, params: ?json.Value) !void {
    const allocator = runtime.allocator;

    // Protect code_cache and remote_tools access
    debug_log_mod.log("handleResourcesRead: acquiring runtime mutex", .{});
    runtime.mutex.lock();
    defer {
        runtime.mutex.unlock();
        debug_log_mod.log("handleResourcesRead: runtime mutex released", .{});
    }
    debug_log_mod.log("handleResourcesRead: runtime mutex acquired", .{});

    const p = params orelse {
        try reply.sendError(-32602, "Missing params");
        return;
    };
    if (p != .object) {
        try reply.sendError(-32602, "Invalid params");
        return;
    }

    const uri_val = p.object.get("uri") orelse {
        try reply.sendError(-32602, "Missing uri");
        return;
    };
    if (uri_val != .string) {
        try reply.sendError(-32602, "uri must be string");
        return;
    }

    const uri = uri_val.string;
    var payload: []const u8 = undefined;
    const mime: []const u8 = "application/json";

    if (std.mem.eql(u8, uri, "cog://debug/tools")) {
        payload = try buildDebugToolsResourceJson(allocator);
    } else if (std.mem.eql(u8, uri, "cog://tools/catalog")) {
        payload = try buildToolCatalogResourceJson(runtime);
    } else {
        try reply.sendError(-32602, "Unknown resource uri");
        return;
    }
    defer allocator.free(payload);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, reply.id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("contents");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("uri");
    try s.write(uri);
    try s.objectField("mimeType");
    try s.write(mime);
    try s.objectField("text");
    try s.write(payload);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try reply.sendRaw(result);
}

fn buildDebugToolsResourceJson(allocator: std.mem.Allocator) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (debug_server_mod.tool_definitions) |tool| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(tool.name);
        try s.objectField("description");
        try s.write(tool.description);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return aw.toOwnedSlice();
}

fn buildToolCatalogResourceJson(runtime: *Runtime) ![]u8 {
    const allocator = runtime.allocator;
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("memory_enabled");
    try s.write(runtime.hasMemory());
    try s.objectField("tools");
    try s.beginArray();
    try writeToolCatalog(runtime, allocator, &s);
    try s.endArray();
    try s.endObject();

    return aw.toOwnedSlice();
}

fn writeToolCatalog(runtime: *Runtime, allocator: std.mem.Allocator, s: *Stringify) !void {
    // All tools are advertised so that host-side sub-agents can discover
    // their schemas via tools/list. The primary agent prompt (PROMPT.md)
    // guides the agent to only use 5 direct memory tools; everything else
    // is accessed through sub-agents (code, debug, memory).

    for (code_tool_definitions) |tool| {
        try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
    }

    // Memory tools: local definitions or dynamically discovered hosted capabilities.
    if (runtime.isLocalBrain()) {
        for (memory_mod.tool_definitions) |tool| {
            try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
        }
    } else if (runtime.brain_type == .remote) {
        if (runtime.remote_tools == null) {
            discoverRemoteTools(runtime) catch |err| {
                debug_log_mod.log("Remote tool discovery failed: {s}", .{@errorName(err)});
            };
        }
        if (runtime.remote_tools) |tools| {
            for (tools) |tool| {
                try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
            }
        }
    }

    // Debug tools must be in tools/list because MCP clients only allow calling
    // tools that appear in the discovered list. The primary agent prompt tells
    // it to delegate to the cog-debug subagent rather than calling these directly.
    for (debug_server_mod.tool_definitions) |tool| {
        if (tool.tier.isWithin(runtime.debug_tool_tier)) {
            try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
        }
    }

    // Observe tools are experimental and only discoverable after explicit opt-in.
    if (runtime.observe_enabled) {
        for (observe_server_mod.tool_definitions) |tool| {
            try writeToolDefWithSchemaJson(allocator, s, tool.name, tool.description, tool.input_schema);
        }
    } else {
        debug_log_mod.log("writeToolCatalog: observe tools disabled", .{});
    }
}

fn findToolByName(comptime definitions: anytype, tool_name: []const u8) ?@TypeOf(definitions[0]) {
    for (definitions) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name)) return tool;
    }
    return null;
}

fn findRemoteTool(runtime: *const Runtime, tool_name: []const u8) ?*const RemoteTool {
    const tools = runtime.remote_tools orelse return null;
    for (tools) |*tool| {
        if (std.mem.eql(u8, tool.name, tool_name)) return tool;
    }
    return null;
}

fn isDebugToolAvailable(runtime: *const Runtime, tool_name: []const u8) bool {
    const tool = findToolByName(debug_server_mod.tool_definitions, tool_name) orelse return false;
    return tool.tier.isWithin(runtime.debug_tool_tier);
}

fn isObserveToolName(tool_name: []const u8) bool {
    return findToolByName(observe_server_mod.tool_definitions, tool_name) != null;
}

fn isObserveToolAvailable(runtime: *const Runtime, tool_name: []const u8) bool {
    return runtime.observe_enabled and runtime.observe_server != null and isObserveToolName(tool_name);
}

fn isRuntimeToolAvailable(runtime: *const Runtime, tool_name: []const u8) bool {
    if (findToolByName(code_tool_definitions, tool_name) != null) return true;
    if (isDebugToolAvailable(runtime, tool_name)) return true;
    if (isObserveToolAvailable(runtime, tool_name)) return true;
    if (runtime.isLocalBrain()) return memory_mod.isLocalToolName(tool_name);
    if (runtime.brain_type == .remote) return findRemoteTool(runtime, tool_name) != null;
    return false;
}

fn runtimeCallTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    // All non-debug tool paths access shared Runtime state.
    debug_log_mod.log("runtimeCallTool: acquiring mutex for {s}", .{tool_name});
    runtime.mutex.lock();
    debug_log_mod.log("runtimeCallTool: mutex acquired for {s}", .{tool_name});
    defer {
        runtime.mutex.unlock();
        debug_log_mod.log("runtimeCallTool: mutex released for {s}", .{tool_name});
    }

    if (runtime.brain_type == .remote and std.mem.startsWith(u8, tool_name, "mem_") and runtime.remote_tools == null) {
        debug_log_mod.log("runtimeCallTool: discovering hosted memory tools before eligibility check", .{});
        try discoverRemoteTools(runtime);
    }
    if (isObserveToolName(tool_name) and (!runtime.observe_enabled or runtime.observe_server == null)) {
        debug_log_mod.log("runtimeCallTool: rejecting disabled observe tool {s}", .{tool_name});
        return error.ObserveDisabled;
    }
    if (!isRuntimeToolAvailable(runtime, tool_name)) {
        debug_log_mod.log("runtimeCallTool: rejecting unavailable tool {s}", .{tool_name});
        return error.ToolUnavailable;
    }

    var session_ctx = try runtime.ensureSessionContext();

    // Debug tools have their own mutex (DebugServer.mutex) — record context first.
    if (isDebugToolAvailable(runtime, tool_name)) {
        const result = try callDebugTool(runtime, tool_name, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }

    // Code tools — these involve SCIP index access and tree-sitter data.
    // Errors are caught and returned as descriptive messages rather than
    // propagating panics from potentially corrupt index data.
    if (std.mem.eql(u8, tool_name, "code_query")) {
        const result = callCodeQuery(runtime, arguments) catch |err| {
            debug_log_mod.log("runtimeCallTool: code_query failed: {s}", .{@errorName(err)});
            return err;
        };
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return withSyncWarning(runtime.allocator, runtime.index_sync_pending.load(.acquire) > 0, applyPendingUpdateNotice(runtime, result));
    } else if (std.mem.eql(u8, tool_name, "code_explore")) {
        const result = callCodeExplore(runtime, arguments) catch |err| {
            debug_log_mod.log("runtimeCallTool: code_explore failed: {s}", .{@errorName(err)});
            return err;
        };
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return withSyncWarning(runtime.allocator, runtime.index_sync_pending.load(.acquire) > 0, applyPendingUpdateNotice(runtime, result));
    }

    // Observe tools — delegate to ObserveServer (has its own mutex).
    if (isObserveToolAvailable(runtime, tool_name)) {
        const result = try callObserveTool(runtime, tool_name, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }

    // Memory tools — local SQLite or remote MCP server
    if (runtime.isLocalBrain() and memory_mod.isLocalToolName(tool_name)) {
        const mem_db = runtime.ensureMemoryDb() catch {
            return runtime.allocator.dupe(u8, "Error: failed to open local memory database.");
        };
        const result = try memory_mod.callLocalTool(mem_db, tool_name, arguments);
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }
    if (runtime.brain_type == .remote and findRemoteTool(runtime, tool_name) != null) {
        const result = try callRemoteHostedTool(runtime, session_ctx, tool_name, arguments);
        session_ctx = try runtime.ensureSessionContext();
        try session_context_mod.recordToolEvent(session_ctx, tool_name, arguments);
        return result;
    }

    return error.Explained;
}

// ── Remote MCP Proxy ────────────────────────────────────────────────────

/// Prefix a remote tool suffix with "mem_".
/// e.g. prefixToolName(alloc, "recall") → "mem_recall"
///      prefixToolName(alloc, "learn") → "mem_learn"
fn prefixToolName(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const prefix = "mem_";
    const buf = try allocator.alloc(u8, prefix.len + suffix.len);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], suffix);
    return buf;
}

/// Rewrite cog_xxx tool name references in descriptions to mem_xxx format.
/// e.g. "use cog_reinforce to..." → "use mem_reinforce to..."
///      "use cog_learn with items" → "use mem_learn with items"
fn rewriteToolReferences(allocator: std.mem.Allocator, desc: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    const prefix = "cog_";
    const replacement_prefix = "mem_";
    var i: usize = 0;
    while (i < desc.len) {
        if (desc.len - i >= prefix.len and std.mem.eql(u8, desc[i..][0..prefix.len], prefix)) {
            // Find end of tool name token (alphanumeric + underscore)
            var end = i + prefix.len;
            while (end < desc.len and (std.ascii.isAlphanumeric(desc[end]) or desc[end] == '_')) : (end += 1) {}
            // Write mem_ + the suffix
            try buf.appendSlice(allocator, replacement_prefix);
            try buf.appendSlice(allocator, desc[i + prefix.len .. end]);
            i = end;
        } else {
            try buf.append(allocator, desc[i]);
            i += 1;
        }
    }

    return try buf.toOwnedSlice(allocator);
}

const BrainIdentity = struct {
    namespace: []const u8,
    name: []const u8,
};

fn parseBrainIdentity(brain_url: []const u8) ?BrainIdentity {
    const https_prefix = "https://";
    const http_prefix = "http://";
    const rest = if (std.mem.startsWith(u8, brain_url, https_prefix))
        brain_url[https_prefix.len..]
    else if (std.mem.startsWith(u8, brain_url, http_prefix))
        brain_url[http_prefix.len..]
    else
        return null;

    const first_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const path = rest[first_slash + 1 ..];
    const second_slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const namespace = path[0..second_slash];
    const name = path[second_slash + 1 ..];
    if (namespace.len == 0 or name.len == 0) return null;
    return .{ .namespace = namespace, .name = name };
}

fn resolveWorkspaceRoot(allocator: std.mem.Allocator, fallback_cwd: []const u8) ![]const u8 {
    const cog_dir = paths.findCogDir(allocator) catch return allocator.dupe(u8, fallback_cwd);
    defer allocator.free(cog_dir);
    const parent = std.fs.path.dirname(cog_dir) orelse return allocator.dupe(u8, fallback_cwd);
    return allocator.dupe(u8, parent);
}

fn detectHostAgentId(allocator: std.mem.Allocator, workspace_root: []const u8) ![]const u8 {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/.cog/client-context.json", .{workspace_root});
    defer allocator.free(manifest_path);
    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch return allocator.dupe(u8, "unknown");
    defer file.close();
    const content = file.readToEndAlloc(allocator, 64 * 1024) catch return allocator.dupe(u8, "unknown");
    defer allocator.free(content);

    const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch return allocator.dupe(u8, "unknown");
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "unknown");
    const agents_val = parsed.value.object.get("selected_agents") orelse return allocator.dupe(u8, "unknown");
    if (agents_val != .array or agents_val.array.items.len == 0) return allocator.dupe(u8, "unknown");
    if (agents_val.array.items.len == 1 and agents_val.array.items[0] == .string) {
        return allocator.dupe(u8, agents_val.array.items[0].string);
    }
    return allocator.dupe(u8, "multi-host");
}

fn discoverRemoteTools(runtime: *Runtime) !void {
    debug_log_mod.log("discoverRemoteTools: starting", .{});
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return;

    // Build MCP endpoint URL: {brain_url}/mcp
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/mcp", .{cfg.brain_url});
    defer allocator.free(endpoint);

    // Build JSON-RPC tools/list request
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";

    const response = try client.mcpCall(allocator, endpoint, cfg.api_key, runtime.mcp_session_id, body);
    defer allocator.free(response.body);

    _ = try updateRemoteSessionId(runtime, response.session_id);

    // Parse response: {"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}
    const parsed = json.parseFromSlice(json.Value, allocator, response.body, .{}) catch return error.InvalidResponse;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    try installRemoteToolsFromResponse(runtime, root);
    debug_log_mod.log("Discovered {d} remote memory tools", .{runtime.remote_tools.?.len});
    debug_log_mod.log("discoverRemoteTools: found {d} tools", .{runtime.remote_tools.?.len});
    debug_log_mod.log(
        "discoverRemoteTools: enhanced_write={s} provenance={any} rationale_trace={any}",
        .{
            if (runtime.remote_memory_capabilities.preferred_write_tool) |value| value else "none",
            runtime.remote_memory_capabilities.supports_provenance_envelopes,
            runtime.remote_memory_capabilities.supports_rationale_trace,
        },
    );
}

fn installRemoteToolsFromResponse(runtime: *Runtime, root: json.Value) !void {
    if (root != .object) return error.InvalidResponse;
    const result_val = root.object.get("result") orelse return error.InvalidResponse;
    if (result_val != .object) return error.InvalidResponse;
    const tools_val = result_val.object.get("tools") orelse return error.InvalidResponse;
    if (tools_val != .array) return error.InvalidResponse;

    if (runtime.remote_tools) |tools| freeRemoteToolSlice(runtime.allocator, tools);
    runtime.remote_tools = null;
    runtime.remote_memory_capabilities.deinit(runtime.allocator);
    runtime.remote_memory_capabilities = .{};

    var tool_list: std.ArrayListUnmanaged(RemoteTool) = .empty;
    errdefer freeRemoteTools(runtime.allocator, &tool_list);
    try collectRemoteTools(runtime.allocator, tools_val.array.items, &runtime.remote_memory_capabilities, &tool_list);
    runtime.remote_tools = try tool_list.toOwnedSlice(runtime.allocator);
}

fn collectRemoteTools(
    allocator: std.mem.Allocator,
    items: []const json.Value,
    capabilities: *memory_envelope_mod.RemoteMemoryCapabilities,
    tool_list: *std.ArrayListUnmanaged(RemoteTool),
) !void {
    try tool_list.ensureUnusedCapacity(allocator, items.len);
    for (items) |item| {
        if (item != .object) continue;

        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const remote_name = name_val.string;
        try memory_envelope_mod.registerCapabilityTool(capabilities, allocator, remote_name);

        const cog_prefix = "cog_";
        if (!std.mem.startsWith(u8, remote_name, cog_prefix)) continue;
        if (memory_envelope_mod.isCapabilityOnlyTool(remote_name)) continue;

        const local_name = try prefixToolName(allocator, remote_name[cog_prefix.len..]);
        errdefer allocator.free(local_name);
        const remote_name_dup = try allocator.dupe(u8, remote_name);
        errdefer allocator.free(remote_name_dup);

        const desc_val = item.object.get("description");
        const desc = if (desc_val) |d| (if (d == .string) d.string else "") else "";
        const desc_dup = try rewriteToolReferences(allocator, desc);
        errdefer allocator.free(desc_dup);

        const schema_val = item.object.get("inputSchema");
        const schema_json = if (schema_val) |schema|
            try client.writeJsonValue(allocator, schema)
        else
            try allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}");
        errdefer allocator.free(schema_json);

        tool_list.appendAssumeCapacity(.{
            .name = local_name,
            .remote_name = remote_name_dup,
            .description = desc_dup,
            .input_schema = schema_json,
        });
    }
}

fn freeRemoteTools(allocator: std.mem.Allocator, tools: *std.ArrayListUnmanaged(RemoteTool)) void {
    for (tools.items) |tool| freeRemoteTool(allocator, tool);
    tools.deinit(allocator);
}

fn freeRemoteToolSlice(allocator: std.mem.Allocator, tools: []RemoteTool) void {
    for (tools) |tool| freeRemoteTool(allocator, tool);
    allocator.free(tools);
}

fn freeRemoteTool(allocator: std.mem.Allocator, tool: RemoteTool) void {
    allocator.free(tool.name);
    allocator.free(tool.remote_name);
    allocator.free(tool.description);
    allocator.free(tool.input_schema);
}

const HostedCallMode = enum { legacy, enhanced };

fn selectHostedCallMode(tool_name: []const u8, capabilities: *const memory_envelope_mod.RemoteMemoryCapabilities) HostedCallMode {
    return if (memory_envelope_mod.isWriteTool(tool_name) and memory_envelope_mod.supportsEnhancedWrite(capabilities)) .enhanced else .legacy;
}

fn callRemoteHostedTool(runtime: *Runtime, session_ctx: *session_context_mod.SessionContext, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    if (selectHostedCallMode(tool_name, &runtime.remote_memory_capabilities) == .legacy) {
        debug_log_mod.log("callRemoteHostedTool: using legacy remote path tool={s} enhanced_supported={any}", .{ tool_name, memory_envelope_mod.supportsEnhancedWrite(&runtime.remote_memory_capabilities) });
        return callRemoteMcpTool(runtime, tool_name, arguments);
    }

    debug_log_mod.log("callRemoteHostedTool: using provenance envelope tool={s} session_bound={any}", .{ tool_name, runtime.mcp_session_id != null });
    const enhanced = try callEnhancedRemoteHostedWrite(runtime, session_ctx, tool_name, arguments);
    if (!enhanced.retry_legacy) return enhanced.text;
    runtime.allocator.free(enhanced.text);

    debug_log_mod.log("callRemoteHostedTool: explicit enhanced rejection; retrying legacy once tool={s}", .{tool_name});
    return callRemoteMcpTool(runtime, tool_name, arguments);
}

const EnhancedRemoteWriteResult = struct {
    text: []const u8,
    retry_legacy: bool,
};

fn callEnhancedRemoteHostedWrite(runtime: *Runtime, session_ctx: *session_context_mod.SessionContext, tool_name: []const u8, arguments: ?json.Value) !EnhancedRemoteWriteResult {
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return error.NotConfigured;
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/mcp", .{cfg.brain_url});
    defer allocator.free(endpoint);

    var write_context = try session_context_mod.buildWriteContext(allocator, session_ctx, tool_name, arguments);
    defer write_context.deinit(allocator);

    const response = try memory_envelope_mod.callEnhancedRemoteWrite(
        allocator,
        endpoint,
        cfg.api_key,
        runtime.mcp_session_id,
        &runtime.remote_memory_capabilities,
        trimMemPrefix(tool_name),
        arguments,
        session_ctx,
        &write_context,
    );
    defer allocator.free(response.body);
    _ = try updateRemoteSessionId(runtime, response.session_id);
    const retry_legacy = isExplicitEnhancedWriteUnsupported(response.body);
    if (retry_legacy) {
        debug_log_mod.log("callEnhancedRemoteHostedWrite: explicit unsupported enhanced response tool={s}", .{tool_name});
    }
    return .{
        .text = try parseRemoteToolTextResponse(allocator, response.body),
        .retry_legacy = retry_legacy,
    };
}

fn callRemoteMcpTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debug_log_mod.log("callRemoteMcpTool: {s}", .{tool_name});
    const allocator = runtime.allocator;
    const cfg = runtime.mem_config orelse return error.NotConfigured;

    if (runtime.remote_tools == null) {
        try discoverRemoteTools(runtime);
    }

    // Find the matching remote tool
    const tools = runtime.remote_tools orelse return error.NotConfigured;
    var remote_name: ?[]const u8 = null;
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name)) {
            remote_name = tool.remote_name;
            break;
        }
    }
    const rname = remote_name orelse return error.Explained;

    // Build MCP endpoint URL
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/mcp", .{cfg.brain_url});
    defer allocator.free(endpoint);

    const args_json = if (arguments) |args|
        try client.writeJsonValue(allocator, args)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(args_json);

    const response = client.mcpCallTool(allocator, endpoint, cfg.api_key, runtime.mcp_session_id, rname, args_json) catch |err| {
        debug_log_mod.log("MCP tool call failed for {s}: {s}", .{ tool_name, @errorName(err) });
        return error.Explained;
    };
    defer allocator.free(response.body);

    _ = try updateRemoteSessionId(runtime, response.session_id);
    return parseRemoteToolTextResponse(allocator, response.body);
}

fn isExplicitEnhancedWriteUnsupported(body: []const u8) bool {
    return memory_envelope_mod.isExplicitUnsupportedEnhancedResponse(std.heap.page_allocator, body);
}

fn updateRemoteSessionId(runtime: *Runtime, new_session_id: ?[]const u8) !bool {
    const new_sid = new_session_id orelse return false;
    if (runtime.mcp_session_id) |old_sid| {
        if (std.mem.eql(u8, old_sid, new_sid)) {
            runtime.allocator.free(new_sid);
            return false;
        }
        runtime.allocator.free(old_sid);
    }
    runtime.mcp_session_id = new_sid;
    clearSessionContexts(runtime);
    _ = try runtime.ensureSessionContext();
    debug_log_mod.log("updateRemoteSessionId: remote session changed; session context rebound", .{});
    return true;
}

fn clearSessionContexts(runtime: *Runtime) void {
    var session_iter = runtime.session_contexts.iterator();
    while (session_iter.next()) |entry| {
        runtime.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    runtime.session_contexts.clearRetainingCapacity();
}

fn parseRemoteToolTextResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return error.Explained;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.Explained;
    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg| {
                if (msg == .string) return allocator.dupe(u8, msg.string);
            }
        }
        return error.Explained;
    }

    const result_val = root.object.get("result") orelse return error.Explained;
    if (result_val != .object) return error.Explained;
    const content_val = result_val.object.get("content") orelse return error.Explained;
    if (content_val != .array) return error.Explained;
    if (content_val.array.items.len == 0) return allocator.dupe(u8, "");
    const first = content_val.array.items[0];
    if (first != .object) return error.Explained;
    const text_val = first.object.get("text") orelse return error.Explained;
    if (text_val != .string) return error.Explained;
    return allocator.dupe(u8, text_val.string);
}

fn trimMemPrefix(tool_name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tool_name, "mem_")) tool_name[4..] else tool_name;
}

// ── Code Tool Handlers ──────────────────────────────────────────────────

fn parseMode(mode_str: []const u8) ?code_intel.QueryMode {
    if (std.mem.eql(u8, mode_str, "find")) return .find;
    if (std.mem.eql(u8, mode_str, "refs")) return .refs;
    if (std.mem.eql(u8, mode_str, "symbols")) return .symbols;
    if (std.mem.eql(u8, mode_str, "imports")) return .imports;
    if (std.mem.eql(u8, mode_str, "contains")) return .contains;
    if (std.mem.eql(u8, mode_str, "calls")) return .calls;
    if (std.mem.eql(u8, mode_str, "callers")) return .callers;
    if (std.mem.eql(u8, mode_str, "overview")) return .overview;
    return null;
}

fn parseDirection(dir: []const u8) code_intel.QueryDirection {
    if (std.mem.eql(u8, dir, "incoming")) return .incoming;
    if (std.mem.eql(u8, dir, "both")) return .both;
    return .outgoing;
}

fn parseScope(scope_str: []const u8) code_intel.OverviewScope {
    if (std.mem.eql(u8, scope_str, "repo")) return .repo;
    if (std.mem.eql(u8, scope_str, "file")) return .file;
    return .symbol;
}

fn parseQueryParams(item: json.Value) ?code_intel.QueryParams {
    const mode_str = getStr(item, "mode") orelse return null;
    const mode = parseMode(mode_str) orelse return null;
    return .{
        .mode = mode,
        .name = getStr(item, "name"),
        .file = getStr(item, "file"),
        .kind = getStr(item, "kind"),
        .direction = if (getStr(item, "direction")) |dir| parseDirection(dir) else .outgoing,
        .scope = if (getStr(item, "scope")) |s| parseScope(s) else .symbol,
    };
}

fn callCodeQuery(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;

    if (runtime.code_cache == null and code_intel.queryIndexStatusForRuntime(allocator) != .ready) {
        return error.IndexUnavailable;
    }

    const ci = try runtime.ensureCodeCache();

    // Batch path: queries array
    const queries_val = if (args == .object) args.object.get("queries") else null;
    if (queries_val) |qv| {
        if (qv == .array) {
            var queries: std.ArrayListUnmanaged(code_intel.QueryParams) = .empty;
            defer queries.deinit(allocator);

            for (qv.array.items) |item| {
                if (parseQueryParams(item)) |params| {
                    try queries.append(allocator, params);
                }
            }

            debug_log_mod.log("callCodeQuery: batch mode, parsed {d} queries", .{queries.items.len});
            if (queries.items.len == 0) return error.Explained;

            return code_intel.codeQueryBatchWithLoadedIndex(allocator, ci, queries.items);
        }
    }

    // Single-query path: flat parameters
    const mode_str = getStr(args, "mode") orelse return error.Explained;
    debug_log_mod.log("callCodeQuery: mode={s}", .{mode_str});
    const mode = parseMode(mode_str) orelse return error.Explained;

    return code_intel.codeQueryWithLoadedIndex(allocator, ci, .{
        .mode = mode,
        .name = getStr(args, "name"),
        .file = getStr(args, "file"),
        .kind = getStr(args, "kind"),
        .direction = if (getStr(args, "direction")) |dir| parseDirection(dir) else .outgoing,
        .scope = if (getStr(args, "scope")) |s| parseScope(s) else .symbol,
    });
}

fn callCodeExplore(runtime: *Runtime, arguments: ?json.Value) ![]const u8 {
    const allocator = runtime.allocator;
    const args = arguments orelse return error.Explained;

    const options = code_intel.ExploreOptions{
        .context_lines = getInt(args, "context_lines") orelse 15,
        .include_relationships = getBool(args, "include_relationships") orelse false,
        .include_architecture = getBool(args, "include_architecture") orelse false,
        .overview_scope = blk: {
            const scope_str = getStr(args, "overview_scope") orelse break :blk .symbol;
            if (std.mem.eql(u8, scope_str, "repo")) break :blk .repo;
            if (std.mem.eql(u8, scope_str, "file")) break :blk .file;
            break :blk .symbol;
        },
    };
    debug_log_mod.log("callCodeExplore: context_lines={d} include_relationships={} include_architecture={} overview_scope={s}", .{ options.context_lines, options.include_relationships, options.include_architecture, @tagName(options.overview_scope) });

    // Parse queries array
    const queries_val = if (args == .object) args.object.get("queries") else null;
    const queries_arr = if (queries_val) |v| (if (v == .array) v.array.items else null) else null;
    if (queries_arr == null) return error.Explained;

    var queries: std.ArrayListUnmanaged(code_intel.ExploreQuery) = .empty;
    defer queries.deinit(allocator);

    for (queries_arr.?) |item| {
        const name = getStr(item, "name") orelse continue;
        try queries.append(allocator, .{
            .name = name,
            .kind = getStr(item, "kind"),
        });
    }

    debug_log_mod.log("callCodeExplore: parsed {d} queries", .{queries.items.len});

    if (queries.items.len == 0) return error.Explained;

    if (runtime.code_cache == null and code_intel.queryIndexStatusForRuntime(allocator) != .ready) {
        return error.IndexUnavailable;
    }

    const ci = try runtime.ensureCodeCache();
    return code_intel.codeExploreWithLoadedIndex(allocator, ci, queries.items, options);
}

// ── File Watcher Event Processing ───────────────────────────────────────

fn collectWatcherEvents(
    runtime: *Runtime,
    paths_buf: *std.ArrayListUnmanaged([]const u8),
    overflow: *bool,
) usize {
    const allocator = runtime.allocator;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (paths_buf.items) |file_path| seen.put(allocator, file_path, {}) catch {};

    var added: usize = 0;
    debug_log_mod.log("watcher batch: acquiring runtime mutex for drain", .{});
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    var watcher = &runtime.watcher.?;
    while (watcher.drainOne()) |event| switch (event) {
        .overflow => overflow.* = true,
        .path => |rel_path| {
            const entry = seen.getOrPut(allocator, rel_path) catch continue;
            if (entry.found_existing) continue;
            const duped = allocator.dupe(u8, rel_path) catch continue;
            paths_buf.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
            added += 1;
        },
    };
    return added;
}

fn processWatcherEvents(
    runtime: *Runtime,
    paths_buf: *std.ArrayListUnmanaged([]const u8),
    overflow: bool,
    index_sync: *IndexSyncState,
) void {
    const allocator = runtime.allocator;
    if (!overflow and paths_buf.items.len == 0) return;

    if (overflow) {
        // Event loss means the whole index may be behind. The reconcile
        // worker converges it without blocking the serve loop, and the
        // pending counter keeps code tools honest meanwhile.
        debug_log_mod.log("watcher batch: overflow; delegating to reconcile worker", .{});
        for (paths_buf.items) |file_path| allocator.free(file_path);
        paths_buf.clearRetainingCapacity();
        index_sync.spawn(runtime, "watcher overflow", std.time.nanoTimestamp());
        return;
    }

    debug_log_mod.log("watcher batch: spawning worker paths={d}", .{paths_buf.items.len});
    _ = runtime.index_sync_pending.fetchAdd(1, .acq_rel);
    defer _ = runtime.index_sync_pending.fetchSub(1, .acq_rel);
    const result = reindexBatchInChunks(allocator, paths_buf.items);

    for (paths_buf.items) |file_path| allocator.free(file_path);
    paths_buf.clearRetainingCapacity();

    if (result == .changed) {
        debug_log_mod.log("watcher batch: acquiring runtime mutex for cache refresh", .{});
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        runtime.syncCodeCacheAfterWrite() catch |err| {
            debug_log_mod.log("watcher batch: cache refresh failed error={s}", .{@errorName(err)});
        };
    }
}

const ReindexWorkerResult = enum {
    changed,
    unchanged,
    failed,
};

fn mergeReindexResults(a: ReindexWorkerResult, b: ReindexWorkerResult) ReindexWorkerResult {
    if (a == .failed or b == .failed) return .failed;
    if (a == .changed or b == .changed) return .changed;
    return .unchanged;
}

/// Run a watcher batch through as many bounded worker calls as it needs.
///
/// A batch can exceed the worker's path count or argument byte limits — a
/// branch switch or a moved directory produces thousands of paths at once.
/// Handing the whole batch to one worker call made the worker reject it and
/// the batch was then freed, so those edits never reached the index. Splitting
/// preserves every path, and a path no argument list can carry escalates to a
/// full resync rather than being dropped.
fn reindexBatchInChunks(allocator: std.mem.Allocator, file_paths: []const []const u8) ReindexWorkerResult {
    if (file_paths.len == 0) return .unchanged;

    var offset: usize = 0;
    var aggregate: ReindexWorkerResult = .unchanged;
    while (offset < file_paths.len) {
        const remaining = file_paths[offset..];
        const chunk_len = code_intel.nextWatcherReindexChunk(remaining);
        if (chunk_len == 0) {
            debug_log_mod.log(
                "watcher batch: path at index {d} cannot be passed as a worker argument; escalating to full resync",
                .{offset},
            );
            return spawnResyncWorker(allocator);
        }

        debug_log_mod.log("watcher batch: worker chunk offset={d} paths={d} of {d}", .{
            offset,
            chunk_len,
            file_paths.len,
        });
        aggregate = mergeReindexResults(aggregate, spawnReindexWorker(allocator, remaining[0..chunk_len]));
        offset += chunk_len;
    }
    return aggregate;
}

fn reindexWorkerResult(term: std.process.Child.Term) ReindexWorkerResult {
    return switch (term) {
        .Exited => |exit_code| switch (exit_code) {
            0 => .changed,
            1 => .unchanged,
            else => .failed,
        },
        .Signal, .Stopped, .Unknown => .failed,
    };
}

fn canSafelyReindexInProcess(file_paths: []const []const u8) bool {
    for (file_paths) |file_path| {
        std.fs.cwd().access(file_path, .{}) catch continue;
        return false;
    }
    return true;
}

fn reindexInProcessAfterSpawnFailure(allocator: std.mem.Allocator, file_paths: []const []const u8) ReindexWorkerResult {
    if (!canSafelyReindexInProcess(file_paths)) {
        debug_log_mod.log("watcher worker: in-process fallback unsafe; live files require isolated worker", .{});
        return .failed;
    }

    debug_log_mod.log("watcher worker: falling back in-process for deleted files", .{});
    var changed = false;
    for (file_paths) |file_path| {
        if (code_intel.removeFileFromIndex(allocator, file_path)) {
            debug_log_mod.log("watcher worker fallback: removed {s}", .{file_path});
            changed = true;
        }
    }
    return if (changed) .changed else .unchanged;
}

pub const index_sync_warning =
    "WARNING: the code index is being reconciled with the working tree; " ++
    "results may be stale. Re-run shortly, or verify critical answers with direct file reads.\n\n";

/// Disclose possible staleness while a reconcile is in flight instead of
/// answering with silent confidence. Takes ownership of `result`.
fn withSyncWarning(allocator: std.mem.Allocator, pending: bool, result: []const u8) ![]const u8 {
    if (!pending) return result;
    const warned = std.fmt.allocPrint(allocator, "{s}{s}", .{ index_sync_warning, result }) catch return result;
    allocator.free(result);
    return warned;
}

test "code tool results disclose an in-flight reconcile" {
    const allocator = std.testing.allocator;

    const untouched = try allocator.dupe(u8, "Matches for `foo`");
    const clean = try withSyncWarning(allocator, false, untouched);
    defer allocator.free(clean);
    try std.testing.expectEqualStrings("Matches for `foo`", clean);

    const stale = try allocator.dupe(u8, "Matches for `foo`");
    const warned = try withSyncWarning(allocator, true, stale);
    defer allocator.free(warned);
    try std.testing.expect(std.mem.startsWith(u8, warned, "WARNING: the code index is being reconciled"));
    try std.testing.expect(std.mem.endsWith(u8, warned, "Matches for `foo`"));
}

/// Prepend `notice_line` to `result`. Takes ownership of `result`; on
/// allocation failure the original result is returned untouched — a missed
/// notice must never break a tool answer.
fn withUpdateNotice(allocator: std.mem.Allocator, notice_line: []const u8, result: []const u8) []const u8 {
    const combined = std.fmt.allocPrint(allocator, "{s}{s}", .{ notice_line, result }) catch return result;
    allocator.free(result);
    return combined;
}

/// Deliver the session's update notice at most once: the first code tool
/// result after the worker reap carries it; the pending state is cleared and
/// the display is confirmed via markNotified. Follows the withSyncWarning
/// precedent of disclosure-by-prefix.
fn applyPendingUpdateNotice(runtime: *Runtime, result: []const u8) []const u8 {
    const pending = runtime.takePendingUpdateNotice() orelse return result;
    defer {
        runtime.allocator.free(pending.line);
        runtime.allocator.free(pending.latest);
    }
    const combined = withUpdateNotice(runtime.allocator, pending.line, result);
    update_check_mod.markNotified(runtime.allocator, pending.latest);
    debug_log_mod.log("update check: notice delivered with code tool result", .{});
    return combined;
}

test "update notices prepend to a code tool result exactly once" {
    const allocator = std.testing.allocator;

    const base = try allocator.dupe(u8, "Matches for `foo`");
    const line = "NOTE: Cog v9.9.9 is available (installed v0.0.1). Ask the user before updating.\n\n";
    const combined = withUpdateNotice(allocator, line, base);
    defer allocator.free(combined);
    try std.testing.expect(std.mem.startsWith(u8, combined, "NOTE: Cog v9.9.9 is available"));
    try std.testing.expect(std.mem.endsWith(u8, combined, "Matches for `foo`"));
}

const git_sentinel_interval_ns: i128 = 2 * std.time.ns_per_s;
const unwatched_sync_interval_ns: i128 = 120 * std.time.ns_per_s;

/// Drives index reconciliation from the serve loop: once at startup, when
/// the git sentinel reports a checkout/pull/merge, and periodically when no
/// file watcher is available. The reconcile itself runs in a re-executed
/// worker process; visibility of its result comes from the per-query index
/// generation check, so completion only has to clear the pending flag.
const max_consecutive_sync_failures: u8 = 2;

const IndexSyncState = struct {
    child: ?std.process.Child = null,
    project_root: ?[]const u8 = null,
    git_stamp: ?git_state.SyncStamp = null,
    last_git_check_ns: i128 = 0,
    last_trigger_ns: i128 = 0,
    consecutive_failures: u8 = 0,
    backoff_logged: bool = false,

    fn tick(self: *IndexSyncState, runtime: *Runtime, now_ns: i128) void {
        if (builtin.os.tag == .windows) return;
        self.reap(runtime);

        if (now_ns - self.last_git_check_ns >= git_sentinel_interval_ns) {
            self.last_git_check_ns = now_ns;
            self.checkGitSentinel(runtime, now_ns);
        }
        if (runtime.watcher == null and now_ns - self.last_trigger_ns >= unwatched_sync_interval_ns) {
            // A worker that keeps failing (no patterns configured, broken
            // settings) must not respawn every period.
            if (self.consecutive_failures >= max_consecutive_sync_failures) {
                if (!self.backoff_logged) {
                    debug_log_mod.log("index sync: periodic reconcile disabled after {d} failures; run cog code:sync to retry", .{self.consecutive_failures});
                    self.backoff_logged = true;
                }
                self.last_trigger_ns = now_ns;
                return;
            }
            self.spawn(runtime, "unwatched periodic", now_ns);
        }
    }

    fn spawn(self: *IndexSyncState, runtime: *Runtime, reason: []const u8, now_ns: i128) void {
        if (builtin.os.tag == .windows) return;
        self.last_trigger_ns = now_ns;
        if (self.child != null) return;
        if (runtime.indexGeneration() == null) {
            debug_log_mod.log("index sync: no index to reconcile ({s})", .{reason});
            return;
        }

        const allocator = runtime.allocator;
        const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
            debug_log_mod.log("index sync: self executable lookup failed error={s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(exe_path);
        const argv = [_][]const u8{ exe_path, code_intel.SYNC_WORKER_COMMAND };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| {
            debug_log_mod.log("index sync: worker spawn failed error={s}", .{@errorName(err)});
            return;
        };
        debug_log_mod.log("index sync: reconcile worker spawned reason={s}", .{reason});
        _ = runtime.index_sync_pending.fetchAdd(1, .acq_rel);
        self.child = child;
    }

    /// Non-blocking reap so the serve loop never stalls behind a reconcile.
    fn reap(self: *IndexSyncState, runtime: *Runtime) void {
        const child = self.child orelse return;
        const wait_result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_result.pid == 0) return;

        self.child = null;
        _ = runtime.index_sync_pending.fetchSub(1, .acq_rel);
        if (std.posix.W.IFEXITED(wait_result.status)) {
            const exit_code = std.posix.W.EXITSTATUS(wait_result.status);
            debug_log_mod.log("index sync: worker exited code={d}", .{exit_code});
            if (exit_code >= 2) {
                self.consecutive_failures +|= 1;
            } else {
                self.consecutive_failures = 0;
                self.backoff_logged = false;
            }
        } else {
            debug_log_mod.log("index sync: worker terminated abnormally", .{});
            self.consecutive_failures +|= 1;
        }
    }

    fn checkGitSentinel(self: *IndexSyncState, runtime: *Runtime, now_ns: i128) void {
        const allocator = runtime.allocator;
        if (self.project_root == null) {
            const cog_dir = paths.findCogDir(allocator) catch return;
            defer allocator.free(cog_dir);
            const root = std.fs.path.dirname(cog_dir) orelse return;
            self.project_root = allocator.dupe(u8, root) catch return;
        }

        const stamp = git_state.syncStamp(allocator, self.project_root.?) orelse return;
        const previous = self.git_stamp orelse {
            self.git_stamp = stamp;
            return;
        };
        if (previous.eql(stamp)) return;

        debug_log_mod.log("index sync: git state changed; reconciling", .{});
        self.git_stamp = stamp;
        self.spawn(runtime, "git state change", now_ns);
    }

    fn deinit(self: *IndexSyncState, allocator: std.mem.Allocator) void {
        // An in-flight worker is deliberately left to finish: it completes
        // the repair on its own and is reparented at process exit.
        if (self.project_root) |root| allocator.free(root);
        self.project_root = null;
    }
};

/// Drives the throttled update check from the serve loop, mirroring
/// IndexSyncState: spawn the hidden worker once at startup (posix only,
/// skipped when opted out), reap it non-blocking, then evaluate the cache
/// exactly once. A due notice is staged on the Runtime; delivery and
/// markNotified happen when a code tool result actually carries it.
const UpdateCheckState = struct {
    child: ?std.process.Child = null,
    evaluated: bool = false,

    fn spawn(self: *UpdateCheckState, runtime: *Runtime) void {
        if (builtin.os.tag == .windows) return;
        if (self.evaluated or self.child != null) return;
        if (update_check_mod.isDisabledByEnv()) {
            debug_log_mod.log("update check: disabled via {s}=0", .{update_check_mod.OPT_OUT_ENV});
            self.evaluated = true;
            return;
        }

        const allocator = runtime.allocator;
        const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
            debug_log_mod.log("update check: self executable lookup failed error={s}", .{@errorName(err)});
            self.evaluated = true;
            return;
        };
        defer allocator.free(exe_path);
        const argv = [_][]const u8{ exe_path, update_check_mod.UPDATE_CHECK_WORKER_COMMAND };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| {
            debug_log_mod.log("update check: worker spawn failed error={s}", .{@errorName(err)});
            self.evaluated = true;
            return;
        };
        debug_log_mod.log("update check: worker spawned", .{});
        self.child = child;
    }

    /// Non-blocking reap so the serve loop never stalls behind the check.
    fn tick(self: *UpdateCheckState, runtime: *Runtime) void {
        if (builtin.os.tag == .windows) return;
        const child = self.child orelse return;
        const wait_result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_result.pid == 0) return;

        self.child = null;
        self.evaluated = true;
        debug_log_mod.log("update check: worker reaped", .{});

        const allocator = runtime.allocator;
        const notice = update_check_mod.pendingNoticeFromCache(allocator) orelse return;
        defer notice.deinit(allocator);
        const line = update_check_mod.formatAgentNotice(allocator, notice) orelse return;
        const latest = allocator.dupe(u8, notice.latest) catch {
            allocator.free(line);
            return;
        };
        runtime.setPendingUpdateNotice(.{ .line = line, .latest = latest });
        debug_log_mod.log("update check: notice staged latest={s}", .{latest});
    }
};

fn spawnResyncWorker(allocator: std.mem.Allocator) ReindexWorkerResult {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        debug_log_mod.log("watcher resync worker: self executable lookup failed error={s}", .{@errorName(err)});
        return .failed;
    };
    defer allocator.free(exe_path);
    const argv = [_][]const u8{ exe_path, code_intel.WATCHER_RESYNC_WORKER_COMMAND };
    debug_log_mod.log("watcher resync worker: spawning executable={s}", .{exe_path});
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        debug_log_mod.log("watcher resync worker: spawn failed error={s}", .{@errorName(err)});
        return .failed;
    };
    const term = child.wait() catch |err| {
        debug_log_mod.log("watcher resync worker: wait failed error={s}", .{@errorName(err)});
        return .failed;
    };
    return reindexWorkerResult(term);
}

fn spawnReindexWorker(allocator: std.mem.Allocator, file_paths: []const []const u8) ReindexWorkerResult {
    code_intel.validateWatcherReindexArgs(file_paths) catch |err| {
        debug_log_mod.log("watcher worker: invalid argv: {s}", .{@errorName(err)});
        return .failed;
    };

    const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| {
        debug_log_mod.log("watcher worker: self executable lookup failed: {s}", .{@errorName(err)});
        return reindexInProcessAfterSpawnFailure(allocator, file_paths);
    };
    defer allocator.free(exe_path);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.ensureTotalCapacity(allocator, file_paths.len + 2) catch |err| {
        debug_log_mod.log("watcher worker: argv allocation failed: {s}", .{@errorName(err)});
        return reindexInProcessAfterSpawnFailure(allocator, file_paths);
    };
    argv.appendAssumeCapacity(exe_path);
    argv.appendAssumeCapacity(code_intel.WATCHER_REINDEX_WORKER_COMMAND);
    for (file_paths) |file_path| argv.appendAssumeCapacity(file_path);

    debug_log_mod.log("watcher worker: spawning executable={s} files={d}", .{ exe_path, file_paths.len });
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        debug_log_mod.log("watcher worker: spawn failed: {s}", .{@errorName(err)});
        return reindexInProcessAfterSpawnFailure(allocator, file_paths);
    };
    debug_log_mod.log("watcher worker: spawned pid={any}", .{child.id});

    const term = child.wait() catch |err| {
        debug_log_mod.log("watcher worker: wait failed: {s}", .{@errorName(err)});
        return .failed;
    };
    const result = reindexWorkerResult(term);
    switch (term) {
        .Exited => |exit_code| debug_log_mod.log("watcher worker: exited code={d} result={s}", .{ exit_code, @tagName(result) }),
        .Signal => |signal| debug_log_mod.log("watcher worker: terminated signal={d} result=failed", .{signal}),
        .Stopped => |signal| debug_log_mod.log("watcher worker: stopped signal={d} result=failed", .{signal}),
        .Unknown => |status| debug_log_mod.log("watcher worker: unknown status={d} result=failed", .{status}),
    }
    return result;
}

fn callDebugTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debug_log_mod.log("callDebugTool: dispatching {s}", .{tool_name});
    const allocator = runtime.allocator;
    const result = runtime.debug_server.callTool(allocator, tool_name, arguments) catch return error.Explained;
    debug_log_mod.log("callDebugTool: {s} returned", .{tool_name});
    return switch (result) {
        .ok => |payload| payload,
        .ok_static => |payload| try allocator.dupe(u8, payload),
        .err => |e| try std.fmt.allocPrint(allocator, "Error {d}: {s}", .{ e.code, e.message }),
    };
}

fn callObserveTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debug_log_mod.log("callObserveTool: dispatching {s}", .{tool_name});
    const allocator = runtime.allocator;
    if (!runtime.observe_enabled) return error.ObserveDisabled;
    const server = if (runtime.observe_server) |*value| value else return error.ObserveDisabled;
    const result = server.callTool(allocator, tool_name, arguments) catch return error.Explained;
    debug_log_mod.log("callObserveTool: {s} returned", .{tool_name});
    return switch (result) {
        .ok => |payload| payload,
        .ok_static => |payload| try allocator.dupe(u8, payload),
        .err => |e| try std.fmt.allocPrint(allocator, "Error {d}: {s}", .{ e.code, e.message }),
    };
}

// ── JSON Helpers ────────────────────────────────────────────────────────

fn getStr(obj: json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getInt(obj: json.Value, key: []const u8) ?usize {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .integer) return null;
    if (val.integer < 0) return null;
    return @intCast(val.integer);
}

fn getBool(obj: json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

const ToolParam = struct {
    name: []const u8,
    typ: []const u8,
    desc: []const u8,
    required: bool,
};

fn writeToolDef(s: *Stringify, name: []const u8, description: []const u8, params: []const ToolParam) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("inputSchema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    for (params) |p| {
        try s.objectField(p.name);
        try s.beginObject();
        try s.objectField("type");
        try s.write(p.typ);
        try s.objectField("description");
        try s.write(p.desc);
        try s.endObject();
    }
    try s.endObject();

    // Required array
    var has_required = false;
    for (params) |p| {
        if (p.required) {
            has_required = true;
            break;
        }
    }
    if (has_required) {
        try s.objectField("required");
        try s.beginArray();
        for (params) |p| {
            if (p.required) try s.write(p.name);
        }
        try s.endArray();
    }

    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();
    try s.endObject();
}

fn writeToolDefWithSchemaJson(allocator: std.mem.Allocator, s: *Stringify, name: []const u8, description: []const u8, schema_json: []const u8) !void {
    const parsed = json.parseFromSlice(json.Value, allocator, schema_json, .{}) catch {
        return writeToolDef(s, name, description, &.{});
    };
    defer parsed.deinit();

    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("inputSchema");
    try s.write(parsed.value);
    try s.endObject();
}

fn writeId(s: *Stringify, id: ?json.Value) !void {
    try s.objectField("id");
    if (id) |v| {
        try s.write(v);
    } else {
        try s.write(null);
    }
}

fn writeToolResult(allocator: std.mem.Allocator, id: ?json.Value, content: []const u8, stdout: StdoutWriter) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(content);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try stdout.writeResponse(result);
}

fn writeToolError(allocator: std.mem.Allocator, id: ?json.Value, message: []const u8, stdout: StdoutWriter) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(message);
    try s.endObject();
    try s.endArray();
    try s.objectField("isError");
    try s.write(true);
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try stdout.writeResponse(result);
}

fn writeError(allocator: std.mem.Allocator, id: ?json.Value, code: i32, message: []const u8, stdout: StdoutWriter) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try writeId(&s, id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    try stdout.writeResponse(result);
}

fn logErr(prefix: []const u8, err: anyerror) void {
    var errbuf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&errbuf);
    w.interface.writeAll(prefix) catch {};
    w.interface.writeAll(@errorName(err)) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

test "handler drain guard is idempotent across normal and error cleanup" {
    var handlers = HandlerThreads.init(1);
    var drained = false;

    try std.testing.expect(drainHandlerThreadsWithin(&handlers, &drained, 10 * std.time.ns_per_ms));
    try std.testing.expect(drained);

    try std.testing.expect(drainHandlerThreadsWithin(&handlers, &drained, 10 * std.time.ns_per_ms));
    try std.testing.expect(drained);
}

test "handler drain guard reports deadline without exiting test process" {
    var handlers = HandlerThreads.init(1);
    const reserved_slot = handlers.begin().?;
    var drained = false;

    handlers.stopAccepting();
    try std.testing.expect(!drainHandlerThreadsWithin(&handlers, &drained, 1 * std.time.ns_per_ms));
    try std.testing.expect(!drained);

    handlers.cancel(reserved_slot);
    try std.testing.expect(drainHandlerThreadsWithin(&handlers, &drained, 10 * std.time.ns_per_ms));
    try std.testing.expect(drained);
}

test "MCP shutdown drains handlers before deinitializing the full runtime" {
    const RuntimeProbe = struct {
        debug_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        observe_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        owned_state_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        deinit_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn deinit(self: *@This()) void {
            self.debug_alive.store(false, .release);
            self.observe_alive.store(false, .release);
            self.owned_state_alive.store(false, .release);
            self.deinit_called.store(true, .release);
        }
    };

    var handlers = HandlerThreads.init(1);
    const slot_index = handlers.begin().?;
    var runtime: RuntimeProbe = .{};
    var allow_finish = std.atomic.Value(bool).init(false);
    var saw_full_runtime_alive = std.atomic.Value(bool).init(false);

    const Handler = struct {
        fn run(
            handler_threads: *HandlerThreads,
            slot: usize,
            probe: *RuntimeProbe,
            finish: *std.atomic.Value(bool),
            saw_alive: *std.atomic.Value(bool),
        ) void {
            while (!finish.load(.acquire)) std.Thread.yield() catch {};
            saw_alive.store(
                probe.debug_alive.load(.acquire) and
                    probe.observe_alive.load(.acquire) and
                    probe.owned_state_alive.load(.acquire),
                .release,
            );
            handler_threads.finish(slot);
        }
    };
    handlers.track(slot_index, try std.Thread.spawn(.{}, Handler.run, .{
        &handlers,
        slot_index,
        &runtime,
        &allow_finish,
        &saw_full_runtime_alive,
    }));

    var drained = false;
    var shutdown_finished = std.atomic.Value(bool).init(false);
    var shutdown_succeeded = std.atomic.Value(bool).init(false);
    const Shutdown = struct {
        fn run(
            handler_threads: *HandlerThreads,
            handlers_drained: *bool,
            probe: *RuntimeProbe,
            finished: *std.atomic.Value(bool),
            succeeded: *std.atomic.Value(bool),
        ) void {
            succeeded.store(
                deinitRuntimeAfterHandlerDrainWithin(handler_threads, handlers_drained, probe, 250 * std.time.ns_per_ms),
                .release,
            );
            finished.store(true, .release);
        }
    };
    const shutdown_thread = try std.Thread.spawn(.{}, Shutdown.run, .{
        &handlers,
        &drained,
        &runtime,
        &shutdown_finished,
        &shutdown_succeeded,
    });
    defer {
        allow_finish.store(true, .release);
        shutdown_thread.join();
    }

    var timer = try std.time.Timer.start();
    while (true) {
        handlers.mutex.lock();
        const accepting = handlers.accepting;
        handlers.mutex.unlock();
        if (!accepting) break;
        if (timer.read() >= 250 * std.time.ns_per_ms) return error.TestTimeout;
        std.Thread.yield() catch {};
    }

    try std.testing.expect(runtime.debug_alive.load(.acquire));
    try std.testing.expect(runtime.observe_alive.load(.acquire));
    try std.testing.expect(runtime.owned_state_alive.load(.acquire));
    try std.testing.expect(!shutdown_finished.load(.acquire));

    allow_finish.store(true, .release);
    timer.reset();
    while (!shutdown_finished.load(.acquire)) {
        if (timer.read() >= 250 * std.time.ns_per_ms) return error.TestTimeout;
        std.Thread.yield() catch {};
    }

    try std.testing.expect(shutdown_succeeded.load(.acquire));
    try std.testing.expect(saw_full_runtime_alive.load(.acquire));
    try std.testing.expect(runtime.deinit_called.load(.acquire));
    try std.testing.expect(!runtime.debug_alive.load(.acquire));
    try std.testing.expect(!runtime.observe_alive.load(.acquire));
    try std.testing.expect(!runtime.owned_state_alive.load(.acquire));
}

test "dispatch write failures propagate to request handler" {
    var mutex: std.Thread.Mutex = .{};
    var reply = ReplyOnce.init(std.testing.allocator, null, .{
        .file = std.fs.File.stdout(),
        .mutex = &mutex,
    });

    try std.testing.expectError(error.WriteFailure, handleDispatchError(&reply, error.WriteFailure));
}

test "unknown method write failures propagate to request handler" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var closed_file = try tmp.dir.createFile("closed-unknown-method", .{});
    closed_file.close();

    var mutex: std.Thread.Mutex = .{};
    var runtime = try testRuntime(std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expectError(error.WriteFailure, processMessage(
        &runtime,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown/method\"}",
        .{ .file = closed_file, .mutex = &mutex },
    ));
}

test "shutdown remains requested when its response write fails" {
    shutdown_requested.store(false, .release);
    defer shutdown_requested.store(false, .release);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var closed_file = try tmp.dir.createFile("closed", .{});
    closed_file.close();

    var mutex: std.Thread.Mutex = .{};
    var reply = ReplyOnce.init(std.testing.allocator, null, .{
        .file = closed_file,
        .mutex = &mutex,
    });

    try std.testing.expectError(error.WriteFailure, handleShutdown(std.testing.allocator, &reply));
    try std.testing.expect(shutdown_requested.load(.acquire));
}

test "IndexGeneration detects identity size and mtime changes" {
    const base = IndexGeneration{ .inode = 1, .size = 10, .mtime = 100 };
    try std.testing.expect(base.eql(.{ .inode = 1, .size = 10, .mtime = 100 }));
    try std.testing.expect(!base.eql(.{ .inode = 2, .size = 10, .mtime = 100 }));
    try std.testing.expect(!base.eql(.{ .inode = 1, .size = 11, .mtime = 100 }));
    try std.testing.expect(!base.eql(.{ .inode = 1, .size = 10, .mtime = 101 }));
}

test "watcher batches split into worker calls that never drop a path" {
    const batch = [_][]const u8{"src/main.zig"} ** (code_intel.MAX_WATCHER_REINDEX_FILES * 2 + 3);

    var offset: usize = 0;
    var calls: usize = 0;
    while (offset < batch.len) {
        const chunk_len = code_intel.nextWatcherReindexChunk(batch[offset..]);
        try std.testing.expect(chunk_len > 0);
        try std.testing.expect(chunk_len <= code_intel.MAX_WATCHER_REINDEX_FILES);
        try code_intel.validateWatcherReindexArgs(batch[offset .. offset + chunk_len]);
        offset += chunk_len;
        calls += 1;
    }

    try std.testing.expectEqual(batch.len, offset);
    try std.testing.expectEqual(@as(usize, 3), calls);
}

test "mergeReindexResults keeps the strongest outcome of a split batch" {
    try std.testing.expectEqual(ReindexWorkerResult.unchanged, mergeReindexResults(.unchanged, .unchanged));
    try std.testing.expectEqual(ReindexWorkerResult.changed, mergeReindexResults(.unchanged, .changed));
    try std.testing.expectEqual(ReindexWorkerResult.changed, mergeReindexResults(.changed, .unchanged));
    try std.testing.expectEqual(ReindexWorkerResult.failed, mergeReindexResults(.changed, .failed));
    try std.testing.expectEqual(ReindexWorkerResult.failed, mergeReindexResults(.failed, .unchanged));
}

test "reindexBatchInChunks reports nothing to do for an empty batch" {
    try std.testing.expectEqual(ReindexWorkerResult.unchanged, reindexBatchInChunks(std.testing.allocator, &.{}));
}

test "reindexWorkerResult maps documented exit statuses" {
    try std.testing.expectEqual(ReindexWorkerResult.changed, reindexWorkerResult(.{ .Exited = 0 }));
    try std.testing.expectEqual(ReindexWorkerResult.unchanged, reindexWorkerResult(.{ .Exited = 1 }));
    try std.testing.expectEqual(ReindexWorkerResult.failed, reindexWorkerResult(.{ .Exited = 2 }));
}

test "reindexWorkerResult treats signal and unexpected statuses as failed" {
    try std.testing.expectEqual(ReindexWorkerResult.failed, reindexWorkerResult(.{ .Signal = 9 }));
    try std.testing.expectEqual(ReindexWorkerResult.failed, reindexWorkerResult(.{ .Stopped = 19 }));
    try std.testing.expectEqual(ReindexWorkerResult.failed, reindexWorkerResult(.{ .Unknown = 255 }));
}

test "canSafelyReindexInProcess only permits missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try tmp.dir.writeFile(.{ .sub_path = "present.zig", .data = "const x = 1;" });
    try std.testing.expect(!canSafelyReindexInProcess(&.{ "missing.zig", "present.zig" }));
    try std.testing.expect(canSafelyReindexInProcess(&.{ "missing.zig", "also-missing.zig" }));
}

test "HandlerThreads caps active handlers" {
    var handlers = HandlerThreads.init(2);
    const first_slot = handlers.begin().?;
    const second_slot = handlers.begin().?;

    const Completion = struct {
        fn run(handler_threads: *HandlerThreads, slot_index: usize) void {
            handler_threads.finish(slot_index);
        }
    };
    handlers.track(first_slot, try std.Thread.spawn(.{}, Completion.run, .{ &handlers, first_slot }));

    const reused_slot = handlers.begin().?;
    try std.testing.expectEqual(first_slot, reused_slot);

    handlers.cancel(reused_slot);
    handlers.cancel(second_slot);
    handlers.stopAccepting();
    try std.testing.expectEqual(HandlerThreads.DrainResult.complete, handlers.drain(10 * std.time.ns_per_ms));
}

test "HandlerThreads begin observes shutdown while waiting at capacity" {
    shutdown_requested.store(false, .release);
    defer shutdown_requested.store(false, .release);

    var handlers = HandlerThreads.init(1);
    const reserved_slot = handlers.begin().?;

    var begin_started = std.atomic.Value(bool).init(false);
    var begin_finished = std.atomic.Value(bool).init(false);
    var acquired_slot = std.atomic.Value(usize).init(MAX_HANDLER_CONCURRENCY);
    const Acquirer = struct {
        fn run(handler_threads: *HandlerThreads, started: *std.atomic.Value(bool), finished: *std.atomic.Value(bool), slot: *std.atomic.Value(usize)) void {
            started.store(true, .release);
            const result = handler_threads.begin();
            slot.store(result orelse MAX_HANDLER_CONCURRENCY, .release);
            finished.store(true, .release);
        }
    };
    const acquire_thread = try std.Thread.spawn(.{}, Acquirer.run, .{ &handlers, &begin_started, &begin_finished, &acquired_slot });
    defer acquire_thread.join();

    while (!begin_started.load(.acquire)) std.Thread.yield() catch {};
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(!begin_finished.load(.acquire));

    shutdown_requested.store(true, .release);
    const deadline = 250 * std.time.ns_per_ms;
    var timer = try std.time.Timer.start();
    while (!begin_finished.load(.acquire) and timer.read() < deadline) std.Thread.yield() catch {};

    try std.testing.expect(begin_finished.load(.acquire));
    try std.testing.expectEqual(MAX_HANDLER_CONCURRENCY, acquired_slot.load(.acquire));

    handlers.cancel(reserved_slot);
    handlers.stopAccepting();
    try std.testing.expectEqual(HandlerThreads.DrainResult.complete, handlers.drain(10 * std.time.ns_per_ms));
}

test "HandlerThreads begin wakes when intake stops at capacity" {
    shutdown_requested.store(false, .release);

    var handlers = HandlerThreads.init(1);
    const reserved_slot = handlers.begin().?;

    var begin_started = std.atomic.Value(bool).init(false);
    var begin_finished = std.atomic.Value(bool).init(false);
    var acquired_slot = std.atomic.Value(usize).init(MAX_HANDLER_CONCURRENCY);
    const Acquirer = struct {
        fn run(handler_threads: *HandlerThreads, started: *std.atomic.Value(bool), finished: *std.atomic.Value(bool), slot: *std.atomic.Value(usize)) void {
            started.store(true, .release);
            const result = handler_threads.begin();
            slot.store(result orelse MAX_HANDLER_CONCURRENCY, .release);
            finished.store(true, .release);
        }
    };
    const acquire_thread = try std.Thread.spawn(.{}, Acquirer.run, .{ &handlers, &begin_started, &begin_finished, &acquired_slot });
    defer acquire_thread.join();

    while (!begin_started.load(.acquire)) std.Thread.yield() catch {};
    std.Thread.sleep(5 * std.time.ns_per_ms);
    try std.testing.expect(!begin_finished.load(.acquire));

    handlers.stopAccepting();
    const deadline = 250 * std.time.ns_per_ms;
    var timer = try std.time.Timer.start();
    while (!begin_finished.load(.acquire) and timer.read() < deadline) std.Thread.yield() catch {};

    try std.testing.expect(begin_finished.load(.acquire));
    try std.testing.expectEqual(MAX_HANDLER_CONCURRENCY, acquired_slot.load(.acquire));

    handlers.cancel(reserved_slot);
    try std.testing.expectEqual(HandlerThreads.DrainResult.complete, handlers.drain(10 * std.time.ns_per_ms));
}

test "HandlerThreads drain times out with a hung worker" {
    var handlers = HandlerThreads.init(1);
    const slot_index = handlers.begin().?;

    var allow_finish = std.atomic.Value(bool).init(false);
    const Handler = struct {
        fn run(handler_threads: *HandlerThreads, slot: usize, finish: *std.atomic.Value(bool)) void {
            while (!finish.load(.acquire)) std.Thread.yield() catch {};
            handler_threads.finish(slot);
        }
    };
    handlers.track(slot_index, try std.Thread.spawn(.{}, Handler.run, .{ &handlers, slot_index, &allow_finish }));
    handlers.stopAccepting();

    try std.testing.expectEqual(HandlerThreads.DrainResult.timed_out, handlers.drain(5 * std.time.ns_per_ms));

    allow_finish.store(true, .release);
    try std.testing.expectEqual(HandlerThreads.DrainResult.complete, handlers.drain(250 * std.time.ns_per_ms));
}

test "HandlerThreads stop accepting and drain tracked handlers" {
    var handlers = HandlerThreads.init(1);
    const slot_index = handlers.begin().?;

    var allow_finish = std.atomic.Value(bool).init(false);
    const Handler = struct {
        fn run(handler_threads: *HandlerThreads, slot: usize, finish: *std.atomic.Value(bool)) void {
            while (!finish.load(.acquire)) std.Thread.yield() catch {};
            handler_threads.finish(slot);
        }
    };
    handlers.track(slot_index, try std.Thread.spawn(.{}, Handler.run, .{ &handlers, slot_index, &allow_finish }));
    handlers.stopAccepting();
    try std.testing.expect(handlers.begin() == null);

    var drain_complete = std.atomic.Value(bool).init(false);
    const Drainer = struct {
        fn run(handler_threads: *HandlerThreads, complete: *std.atomic.Value(bool)) void {
            const result = handler_threads.drain(250 * std.time.ns_per_ms);
            complete.store(result == .complete, .release);
        }
    };
    const drain_thread = try std.Thread.spawn(.{}, Drainer.run, .{ &handlers, &drain_complete });
    defer drain_thread.join();

    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(!drain_complete.load(.acquire));

    allow_finish.store(true, .release);
    while (!drain_complete.load(.acquire)) std.Thread.yield() catch {};
}

test "nextMessageFromBuffer extracts newline-delimited JSON" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, body ++ "\n");

    const framed = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed) {
        .message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings(body, msg);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "nextMessageFromBuffer handles multiple messages" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    const msg1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    const msg2 = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, msg1 ++ "\n" ++ msg2 ++ "\n");

    const framed1 = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed1) {
        .message => |result1| {
            defer allocator.free(result1);
            try std.testing.expectEqualStrings(msg1, result1);
        },
        else => return error.TestUnexpectedResult,
    }

    const framed2 = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed2) {
        .message => |result2| {
            defer allocator.free(result2);
            try std.testing.expectEqualStrings(msg2, result2);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "nextMessageFromBuffer skips leading whitespace" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, "\n\n  " ++ body ++ "\n");

    const framed = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed) {
        .message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings(body, msg);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextMessageFromBuffer preserves brace fallback" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    // Incomplete JSON line (no trailing newline) but a complete JSON object
    // should still be extractable via brace counting.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    try buf.appendSlice(allocator, body);

    const framed = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed) {
        .message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings(body, msg);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextMessageFromBuffer returns null for incomplete JSON" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    const partial = "{\"jsonrpc\":\"2.0\",\"id\":1";
    try buf.appendSlice(allocator, partial);
    const msg = try nextMessageFromBuffer(allocator, &buf, &state);
    try std.testing.expect(msg == null);
    try std.testing.expect(buf.items.len == partial.len);
}

test "MCP transport frame limit is a public byte-exact contract" {
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), max_transport_frame_bytes);
    try std.testing.expectEqualStrings("4 MiB (4,194,304 bytes)", max_transport_frame_size_label);
}

test "nextMessageFromBuffer accepts a message at the size limit" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    try buf.appendNTimes(allocator, 'x', max_transport_frame_bytes);
    try buf.append(allocator, '\n');

    const framed = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed) {
        .message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqual(max_transport_frame_bytes, msg.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextMessageFromBuffer tags an oversized complete line and resyncs" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    try buf.appendNTimes(allocator, 'x', max_transport_frame_bytes + 1);
    try buf.appendSlice(allocator, "\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");

    const oversized = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    try std.testing.expect(oversized == .oversized_complete);

    const framed = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed) {
        .message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}", msg);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "nextMessageFromBuffer tags an oversized brace-complete message" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    try buf.append(allocator, '{');
    try buf.appendNTimes(allocator, ' ', max_transport_frame_bytes - 1);
    try buf.append(allocator, '}');

    const oversized = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    try std.testing.expect(oversized == .oversized_complete);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "nextMessageFromBuffer tags an oversized partial line and discards through newline" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var state: MessageFramingState = .{};

    try buf.appendNTimes(allocator, 'x', max_transport_frame_bytes + 1);
    const oversized = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    try std.testing.expect(oversized == .oversized_partial);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
    try std.testing.expect(state.discarding_oversized);

    try appendFramingInput(allocator, &buf, &state, "discarded tail");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
    try std.testing.expect(state.discarding_oversized);

    try appendFramingInput(allocator, &buf, &state, "\n{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n");
    try std.testing.expect(!state.discarding_oversized);

    const framed = (try nextMessageFromBuffer(allocator, &buf, &state)).?;
    switch (framed) {
        .message => |msg| {
            defer allocator.free(msg);
            try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}", msg);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn testSessionContext(allocator: std.mem.Allocator, session_id: []const u8) !session_context_mod.SessionContext {
    var repo_context = repo_context_mod.RepoContext{
        .cwd = try allocator.dupe(u8, "/tmp/project"),
        .repo_root = null,
        .repo_remote_origin = null,
        .repo_head_sha = null,
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(allocator);

    return session_context_mod.initSessionContext(
        allocator,
        session_id,
        "test-host",
        null,
        null,
        "/tmp/project",
        "https://trycog.ai/acme/brain",
        "acme",
        "brain",
        &repo_context,
    );
}

const TestBrain = enum { none, local, remote };

const TestRuntimeOptions = struct {
    brain: TestBrain = .none,
    observe_enabled: bool = true,
    debug_tool_tier: ToolTier = .specialist,
    remote_tools: []const RemoteTool = &.{},
};

fn testRuntimeWithOptions(allocator: std.mem.Allocator, options: TestRuntimeOptions) !Runtime {
    const brain_type: config_mod.BrainType = switch (options.brain) {
        .none => .none,
        .local => blk: {
            const path = try allocator.dupe(u8, "/nonexistent/cog-test-brain.db");
            errdefer allocator.free(path);
            break :blk .{ .local = .{
                .path = path,
                .brain_id = try allocator.dupe(u8, "test-brain"),
            } };
        },
        .remote => blk: {
            const api_key = try allocator.dupe(u8, "test-key");
            errdefer allocator.free(api_key);
            const url = try allocator.dupe(u8, "https://example.invalid/api/v1/test/brain");
            errdefer allocator.free(url);
            break :blk .{ .remote = .{
                .api_key = api_key,
                .url = url,
                .brain_url = try allocator.dupe(u8, "https://example.invalid/test/brain"),
            } };
        },
    };
    errdefer brain_type.deinit(allocator);

    var runtime: Runtime = .{
        .allocator = allocator,
        .mem_config = switch (brain_type) {
            .remote => |config| config,
            else => null,
        },
        .brain_type = brain_type,
        .mem_db = null,
        .debug_server = DebugServer.init(allocator),
        .observe_enabled = options.observe_enabled,
        .observe_server = null,
        .code_cache = null,
        .remote_tools = null,
        .mcp_session_id = null,
        .watcher = null,
        .debug_tool_tier = options.debug_tool_tier,
        .mutex = .{},
    };
    errdefer runtime.deinit();
    if (options.observe_enabled) runtime.observe_server = try ObserveServer.init(allocator);

    if (options.brain == .remote) {
        const tools = try allocator.alloc(RemoteTool, options.remote_tools.len);
        runtime.remote_tools = tools;
        var initialized: usize = 0;
        errdefer {
            for (tools[0..initialized]) |tool| {
                allocator.free(tool.name);
                allocator.free(tool.remote_name);
                allocator.free(tool.description);
                allocator.free(tool.input_schema);
            }
            allocator.free(tools);
            runtime.remote_tools = null;
        }
        for (options.remote_tools, 0..) |tool, i| {
            const name = try allocator.dupe(u8, tool.name);
            errdefer allocator.free(name);
            const remote_name = try allocator.dupe(u8, tool.remote_name);
            errdefer allocator.free(remote_name);
            const description = try allocator.dupe(u8, tool.description);
            errdefer allocator.free(description);
            tools[i] = .{
                .name = name,
                .remote_name = remote_name,
                .description = description,
                .input_schema = try allocator.dupe(u8, tool.input_schema),
            };
            initialized += 1;
        }
    }

    return runtime;
}

fn testRuntime(allocator: std.mem.Allocator) !Runtime {
    return testRuntimeWithOptions(allocator, .{});
}

fn catalogContains(tools: json.Array, name: []const u8) bool {
    for (tools.items) |tool| {
        if (tool != .object) continue;
        const name_value = tool.object.get("name") orelse continue;
        if (name_value == .string and std.mem.eql(u8, name_value.string, name)) return true;
    }
    return false;
}

fn countCatalogTools(tools: json.Array, prefix: []const u8) usize {
    var count: usize = 0;
    for (tools.items) |tool| {
        if (tool != .object) continue;
        const name_value = tool.object.get("name") orelse continue;
        if (name_value == .string and std.mem.startsWith(u8, name_value.string, prefix)) count += 1;
    }
    return count;
}

fn expectedCatalogToolCount(runtime: *const Runtime) usize {
    var count: usize = code_tool_definitions.len;
    if (runtime.isLocalBrain()) {
        count += memory_mod.tool_definitions.len;
    } else if (runtime.brain_type == .remote) {
        count += if (runtime.remote_tools) |tools| tools.len else 0;
    }
    for (debug_server_mod.tool_definitions) |tool| {
        if (tool.tier.isWithin(runtime.debug_tool_tier)) count += 1;
    }
    if (runtime.observe_enabled) count += observe_server_mod.tool_definitions.len;
    return count;
}

fn expectCatalogMatchesDispatchEligibility(runtime: *Runtime) !void {
    const catalog = try buildToolCatalogResourceJson(runtime);
    defer std.testing.allocator.free(catalog);
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, catalog, .{});
    defer parsed.deinit();

    const tools_value = parsed.value.object.get("tools") orelse return error.TestUnexpectedResult;
    if (tools_value != .array) return error.TestUnexpectedResult;
    try std.testing.expectEqual(expectedCatalogToolCount(runtime), tools_value.array.items.len);

    for (tools_value.array.items, 0..) |tool, i| {
        if (tool != .object) return error.TestUnexpectedResult;
        const name_value = tool.object.get("name") orelse return error.TestUnexpectedResult;
        if (name_value != .string) return error.TestUnexpectedResult;
        try std.testing.expect(isRuntimeToolAvailable(runtime, name_value.string));
        for (tools_value.array.items[0..i]) |earlier| {
            const earlier_name = earlier.object.get("name") orelse return error.TestUnexpectedResult;
            try std.testing.expect(!std.mem.eql(u8, earlier_name.string, name_value.string));
        }
    }

    for (code_tool_definitions) |tool| try std.testing.expect(catalogContains(tools_value.array, tool.name));
    try std.testing.expectEqual(code_tool_definitions.len, countCatalogTools(tools_value.array, "code_"));

    var expected_debug_count: usize = 0;
    for (debug_server_mod.tool_definitions) |tool| {
        const expected = tool.tier.isWithin(runtime.debug_tool_tier);
        if (expected) expected_debug_count += 1;
        try std.testing.expectEqual(expected, catalogContains(tools_value.array, tool.name));
    }
    try std.testing.expectEqual(expected_debug_count, countCatalogTools(tools_value.array, "debug_"));

    for (observe_server_mod.tool_definitions) |tool| {
        try std.testing.expectEqual(runtime.observe_enabled, catalogContains(tools_value.array, tool.name));
    }
    try std.testing.expectEqual(if (runtime.observe_enabled) observe_server_mod.tool_definitions.len else 0, countCatalogTools(tools_value.array, "observe_"));

    for (memory_mod.tool_definitions) |tool| {
        try std.testing.expectEqual(runtime.isLocalBrain(), catalogContains(tools_value.array, tool.name));
    }
    if (runtime.remote_tools) |remote_tools| {
        for (remote_tools) |tool| try std.testing.expect(catalogContains(tools_value.array, tool.name));
    }
    const expected_memory_count = if (runtime.isLocalBrain())
        memory_mod.tool_definitions.len
    else if (runtime.remote_tools) |remote_tools|
        remote_tools.len
    else
        0;
    try std.testing.expectEqual(expected_memory_count, countCatalogTools(tools_value.array, "mem_"));
}

test "MCP catalog and dispatch eligibility agree across capability gates" {
    const remote_tools = [_]RemoteTool{
        .{
            .name = "mem_remote_only",
            .remote_name = "cog_remote_only",
            .description = "Remote-only test capability",
            .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        },
    };
    const cases = [_]TestRuntimeOptions{
        .{ .observe_enabled = false, .debug_tool_tier = .core },
        .{ .brain = .local, .observe_enabled = true, .debug_tool_tier = .extended },
        .{ .brain = .remote, .observe_enabled = false, .debug_tool_tier = .specialist, .remote_tools = &remote_tools },
    };

    for (cases) |options| {
        var runtime = try testRuntimeWithOptions(std.testing.allocator, options);
        defer runtime.deinit();
        try expectCatalogMatchesDispatchEligibility(&runtime);
    }
}

test "MCP dispatch rejects unknown names that share tool prefixes" {
    var runtime = try testRuntimeWithOptions(std.testing.allocator, .{
        .brain = .local,
        .observe_enabled = true,
        .debug_tool_tier = .core,
    });
    defer runtime.deinit();

    const unknown_names = [_][]const u8{
        "debug_not_a_tool",
        "observe_not_a_tool",
        "mem_not_a_tool",
        "code_not_a_tool",
    };
    for (unknown_names) |name| {
        try std.testing.expect(!isRuntimeToolAvailable(&runtime, name));
        try std.testing.expectError(error.ToolUnavailable, runtimeCallTool(&runtime, name, null));
    }
}

test "MCP debug dispatch respects configured tool tier" {
    var runtime = try testRuntimeWithOptions(std.testing.allocator, .{
        .observe_enabled = false,
        .debug_tool_tier = .core,
    });
    defer runtime.deinit();

    try std.testing.expect(isRuntimeToolAvailable(&runtime, "debug_launch"));
    try std.testing.expect(!isRuntimeToolAvailable(&runtime, "debug_threads"));
    try std.testing.expect(!isRuntimeToolAvailable(&runtime, "debug_registers"));
    try std.testing.expectError(error.ToolUnavailable, runtimeCallTool(&runtime, "debug_threads", null));
    try std.testing.expectError(error.ToolUnavailable, runtimeCallTool(&runtime, "debug_registers", null));
}

test "MCP memory dispatch separates local and hosted capabilities" {
    const remote_tools = [_]RemoteTool{
        .{
            .name = "mem_remote_only",
            .remote_name = "cog_remote_only",
            .description = "Remote-only test capability",
            .input_schema = "{\"type\":\"object\",\"properties\":{}}",
        },
    };

    var local = try testRuntimeWithOptions(std.testing.allocator, .{ .brain = .local, .observe_enabled = false });
    defer local.deinit();
    try std.testing.expect(isRuntimeToolAvailable(&local, "mem_recall"));
    try std.testing.expect(!isRuntimeToolAvailable(&local, "mem_remote_only"));

    var hosted = try testRuntimeWithOptions(std.testing.allocator, .{
        .brain = .remote,
        .observe_enabled = false,
        .remote_tools = &remote_tools,
    });
    defer hosted.deinit();
    try std.testing.expect(!isRuntimeToolAvailable(&hosted, "mem_recall"));
    try std.testing.expect(isRuntimeToolAvailable(&hosted, "mem_remote_only"));
    try std.testing.expect(!isRuntimeToolAvailable(&hosted, "mem_not_discovered"));
    try std.testing.expectError(error.ToolUnavailable, runtimeCallTool(&hosted, "mem_not_discovered", null));
}

test "tool catalog omits observe tools when observe is disabled" {
    var runtime = try testRuntimeWithOptions(std.testing.allocator, .{ .observe_enabled = false });
    defer runtime.deinit();

    const catalog = try buildToolCatalogResourceJson(&runtime);
    defer std.testing.allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "observe_status") == null);
}

test "tool catalog includes observe tools when observe is enabled" {
    var runtime = try testRuntime(std.testing.allocator);
    defer runtime.deinit();

    const catalog = try buildToolCatalogResourceJson(&runtime);
    defer std.testing.allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "observe_status") != null);
}

test "runtimeCallTool rejects exact observe tools when observe is disabled" {
    var runtime = try testRuntimeWithOptions(std.testing.allocator, .{ .observe_enabled = false });
    defer runtime.deinit();

    try std.testing.expectError(error.ObserveDisabled, runtimeCallTool(&runtime, "observe_status", null));
    try std.testing.expectError(error.ToolUnavailable, runtimeCallTool(&runtime, "observe_not_a_tool", null));
}

test "remote tool discovery registers capability-only tools without exposing them" {
    const allocator = std.testing.allocator;
    var runtime = try testRuntime(allocator);
    defer runtime.deinit();

    const response = try json.parseFromSlice(json.Value, allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[
        \\  {"name":"cog_memory_record","description":"enhanced write proxy","inputSchema":{"type":"object"}},
        \\  {"name":"cog_learn","description":"learn a memory","inputSchema":{"type":"object","properties":{"term":{"type":"string"}}}}
        \\]}}
    , .{});
    defer response.deinit();

    try installRemoteToolsFromResponse(&runtime, response.value);

    try std.testing.expect(memory_envelope_mod.supportsEnhancedWrite(&runtime.remote_memory_capabilities));
    try std.testing.expectEqual(@as(usize, 1), runtime.remote_tools.?.len);
    try std.testing.expectEqualStrings("mem_learn", runtime.remote_tools.?[0].name);
    try std.testing.expectEqualStrings("cog_learn", runtime.remote_tools.?[0].remote_name);
}

test "hosted writes use envelopes only when supported" {
    var capabilities = memory_envelope_mod.RemoteMemoryCapabilities{};
    defer capabilities.deinit(std.testing.allocator);

    try std.testing.expectEqual(HostedCallMode.legacy, selectHostedCallMode("mem_learn", &capabilities));
    try memory_envelope_mod.registerCapabilityTool(&capabilities, std.testing.allocator, "cog_memory_record");
    try std.testing.expectEqual(HostedCallMode.enhanced, selectHostedCallMode("mem_learn", &capabilities));
    try std.testing.expectEqual(HostedCallMode.legacy, selectHostedCallMode("mem_recall", &capabilities));
}

test "enhanced write fallback is limited to explicit unsupported responses" {
    try std.testing.expect(isExplicitEnhancedWriteUnsupported(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Tool cog_memory_record is not supported"}}
    ));
    try std.testing.expect(isExplicitEnhancedWriteUnsupported(
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"input schema validation failed: unknown field provenance"}],"isError":true}}
    ));
    try std.testing.expect(!isExplicitEnhancedWriteUnsupported(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"temporary upstream failure"}}
    ));
    try std.testing.expect(!isExplicitEnhancedWriteUnsupported("not-json"));
}

test "remote session changes rebind the active context" {
    const allocator = std.testing.allocator;
    var runtime = try testRuntime(allocator);
    defer runtime.deinit();

    try runtime.session_contexts.ensureTotalCapacity(allocator, 1);
    var old_ctx = try testSessionContext(allocator, "remote-old");
    const old_key = try allocator.dupe(u8, "remote-old");
    runtime.session_contexts.putAssumeCapacity(old_key, old_ctx);
    runtime.mcp_session_id = try allocator.dupe(u8, "remote-old");

    const new_sid = try allocator.dupe(u8, "remote-new");
    _ = try updateRemoteSessionId(&runtime, new_sid);

    try std.testing.expect(runtime.session_contexts.get("remote-old") == null);
    const rebound = runtime.session_contexts.getPtr("remote-new") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("remote-new", rebound.session_id);
    old_ctx = undefined;
}

test "runtimeCallTool rebinds context after first-call remote discovery" {
    const source = @embedFile("mcp.zig");
    const runtime_call_start = std.mem.indexOf(
        u8,
        source,
        "fn runtimeCallTool(runtime: *Runtime, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {",
    ) orelse return error.TestUnexpectedResult;
    const discovery = std.mem.indexOfPos(u8, source, runtime_call_start, "try discoverRemoteTools(runtime);") orelse return error.TestUnexpectedResult;
    const remote_call = std.mem.indexOfPos(u8, source, discovery, "callRemoteHostedTool(runtime, session_ctx, tool_name, arguments)") orelse return error.TestUnexpectedResult;
    const between_discovery_and_call = source[discovery..remote_call];

    try std.testing.expect(std.mem.indexOf(u8, between_discovery_and_call, "var session_ctx = try runtime.ensureSessionContext()") != null);
}

test "runtimeCallTool keeps runtime mutex held across remote calls and event recording" {
    const source = @embedFile("mcp.zig");
    const remote_branch_start = std.mem.indexOf(
        u8,
        source,
        "    if (runtime.brain_type == .remote and findRemoteTool(runtime, tool_name) != null) {",
    ) orelse return error.TestUnexpectedResult;
    const remote_branch_end = std.mem.indexOfPos(
        u8,
        source,
        remote_branch_start,
        "        return result;\n    }\n",
    ) orelse return error.TestUnexpectedResult;
    const remote_branch = source[remote_branch_start..remote_branch_end];

    try std.testing.expect(std.mem.indexOf(u8, remote_branch, "runtime.mutex.unlock()") == null);
    try std.testing.expect(std.mem.indexOf(u8, remote_branch, "runtime.mutex.lock()") == null);

    const remote_call = std.mem.indexOf(u8, remote_branch, "callRemoteHostedTool(runtime, session_ctx, tool_name, arguments)") orelse return error.TestUnexpectedResult;
    const rebind_context = std.mem.indexOfPos(u8, remote_branch, remote_call, "session_ctx = try runtime.ensureSessionContext()") orelse return error.TestUnexpectedResult;
    const record_event = std.mem.indexOf(u8, remote_branch, "session_context_mod.recordToolEvent(session_ctx, tool_name, arguments)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(remote_call < rebind_context);
    try std.testing.expect(rebind_context < record_event);
}

test "capability-only hosted tools stay hidden while registering support" {
    const allocator = std.testing.allocator;
    var capabilities = memory_envelope_mod.RemoteMemoryCapabilities{};
    defer capabilities.deinit(allocator);
    var visible_tools: std.ArrayListUnmanaged(RemoteTool) = .empty;
    defer freeRemoteTools(allocator, &visible_tools);

    const parsed = try json.parseFromSlice(
        json.Value,
        allocator,
        "{\"tools\":[{\"name\":\"cog_memory_record\",\"description\":\"capability\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"cog_learn\",\"description\":\"learn\",\"inputSchema\":{\"type\":\"object\"}}]}",
        .{},
    );
    defer parsed.deinit();

    try collectRemoteTools(allocator, parsed.value.object.get("tools").?.array.items, &capabilities, &visible_tools);

    try std.testing.expect(memory_envelope_mod.supportsEnhancedWrite(&capabilities));
    try std.testing.expectEqual(@as(usize, 1), visible_tools.items.len);
    try std.testing.expectEqualStrings("mem_learn", visible_tools.items[0].name);
}

test "remote session changes rebind hosted session context" {
    const allocator = std.testing.allocator;
    var runtime = try testRuntime(allocator);
    defer runtime.deinit();

    runtime.mcp_session_id = try allocator.dupe(u8, "remote-old");
    var repo_context = repo_context_mod.RepoContext{
        .cwd = try allocator.dupe(u8, "/tmp/project"),
        .repo_root = try allocator.dupe(u8, "/tmp/project"),
        .repo_remote_origin = null,
        .repo_head_sha = null,
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(allocator);
    const context = try session_context_mod.initSessionContext(
        allocator,
        "remote-old",
        "test-agent",
        null,
        null,
        "/tmp/project",
        "https://trycog.ai/acme/brain",
        "acme",
        "brain",
        &repo_context,
    );
    const owned_key = try allocator.dupe(u8, "remote-old");
    try runtime.session_contexts.put(allocator, owned_key, context);

    try std.testing.expect(try updateRemoteSessionId(&runtime, try allocator.dupe(u8, "remote-new")));
    try std.testing.expectEqualStrings("remote-new", runtime.mcp_session_id.?);
    try std.testing.expect(runtime.session_contexts.get("remote-old") == null);
}

test "runtimeCallTool rejects code queries when index is unavailable" {
    const allocator = std.testing.allocator;
    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    var root_dir = try std.fs.openDirAbsolute("/", .{});
    defer root_dir.close();
    try root_dir.setAsCwd();

    var runtime = try testRuntime(allocator);
    defer runtime.deinit();

    const parsed = try json.parseFromSlice(json.Value, allocator, "{\"mode\":\"find\",\"name\":\"main\"}", .{});
    defer parsed.deinit();

    try std.testing.expectError(error.IndexUnavailable, runtimeCallTool(&runtime, "code_query", parsed.value));
}
