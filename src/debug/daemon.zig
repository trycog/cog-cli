const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const debug_log = @import("../debug_log.zig");
const paths = @import("../paths.zig");
const server_mod = @import("server.zig");
const ipc_identity = @import("ipc_identity.zig");
const DebugServer = server_mod.DebugServer;
const ToolResult = server_mod.ToolResult;

// ── Daemon Server ───────────────────────────────────────────────────────

pub const DaemonServer = struct {
    const IDLE_TIMEOUT_MS: i64 = 5 * 60 * 1000; // 5 minutes
    const DEFAULT_SESSION_IDLE_TIMEOUT_MS: i64 = 10 * 60 * 1000; // 10 minutes per-session

    allocator: std.mem.Allocator,
    server: DebugServer,
    socket_fd: ?posix.socket_t = null,
    socket_path: ?[]const u8 = null,
    socket_owner_lock: ?paths.SocketOwnerLock = null,
    pid_path: ?[]const u8 = null,
    last_activity: i64 = 0,
    session_idle_timeout_ms: i64 = DEFAULT_SESSION_IDLE_TIMEOUT_MS,

    pub fn init(allocator: std.mem.Allocator, session_idle_timeout_ms: ?i64) DaemonServer {
        return .{
            .allocator = allocator,
            .server = DebugServer.init(allocator),
            .last_activity = std.time.milliTimestamp(),
            .session_idle_timeout_ms = session_idle_timeout_ms orelse DEFAULT_SESSION_IDLE_TIMEOUT_MS,
        };
    }

    pub fn deinit(self: *DaemonServer) void {
        if (self.socket_fd) |fd| {
            debug_log.log("DaemonServer.deinit: closing listener fd={d}", .{fd});
            posix.close(fd);
            self.socket_fd = null;
        }
        if (self.socket_path) |path| {
            debug_log.log("DaemonServer.deinit: removing owned socket {s}", .{path});
            paths.removeOwnedSocketIfPresent(path) catch |err| {
                debug_log.log("DaemonServer.deinit: preserving unsafe socket path {s}: {s}", .{ path, @errorName(err) });
            };
            self.allocator.free(path);
            self.socket_path = null;
        }
        if (self.pid_path) |path| {
            debug_log.log("DaemonServer.deinit: removing published PID file {s}", .{path});
            std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => debug_log.log("DaemonServer.deinit: failed to remove PID file {s}: {s}", .{ path, @errorName(err) }),
            };
            self.allocator.free(path);
            self.pid_path = null;
        }
        // Released only after the socket unlink above so no other starter can
        // take over the path mid-teardown.
        if (self.socket_owner_lock) |*lock| {
            debug_log.log("DaemonServer.deinit: releasing socket owner lock", .{});
            lock.release();
            self.socket_owner_lock = null;
        }
        self.server.deinit();
    }

    pub fn run(self: *DaemonServer) !void {
        // Report retired shared paths without trusting or removing them.
        paths.logLegacyDebugPaths();

        // Set up signal handler for clean shutdown
        setupSignalHandler();

        // Connect to dashboard TUI if one is running
        self.server.connectDashboardSocket();

        // Create and bind the Unix domain socket
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        const sock_path = try paths.getDaemonSocketPath(self.allocator);
        paths.validateUnixSocketPath(sock_path) catch |err| {
            self.allocator.free(sock_path);
            return err;
        };

        // Serialize the whole takeover — probe, unlink, bind — against every
        // other same-user starter, and hold the lock until teardown finishes.
        std.debug.assert(self.socket_owner_lock == null);
        self.socket_owner_lock = paths.acquireSocketOwnerLock(self.allocator, sock_path) catch |err| {
            debug_log.log("DaemonServer.run: socket owner lock unavailable for {s}: {s}", .{ sock_path, @errorName(err) });
            self.allocator.free(sock_path);
            return err;
        };

        // Remove only an owned socket node. Never unlink a regular file or
        // symlink that happens to occupy the runtime pathname.
        paths.removeOwnedSocketIfPresent(sock_path) catch |err| {
            debug_log.log("DaemonServer.run: preserving unsafe socket path {s}: {s}", .{ sock_path, @errorName(err) });
            self.allocator.free(sock_path);
            return err;
        };
        std.debug.assert(self.socket_path == null);
        self.socket_path = sock_path;

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..sock_path.len], sock_path);

        debug_log.log("DaemonServer.run: binding socket {s}", .{sock_path});
        try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        if (@import("builtin").os.tag != .windows) try std.posix.fchmodat(std.posix.AT.FDCWD, sock_path, 0o600, 0);
        try posix.listen(sock, 8);

        self.socket_fd = sock;

        // PID publication is required because clients refuse to signal an
        // unverified or stale process identity.
        self.writePidFile() catch |err| {
            debug_log.log("DaemonServer.run: failed to write PID file: {s}", .{@errorName(err)});
            return err;
        };

        // Store socket path for signal handler cleanup
        @memcpy(g_daemon_socket_path[0..sock_path.len], sock_path);
        g_daemon_socket_path_len = sock_path.len;

        // Accept loop with idle timeout
        while (!g_shutdown_requested) {
            // Reap sessions whose owner process no longer exists.
            self.reapOrphanedSessions();

            // Check idle timeout
            const now = std.time.milliTimestamp();
            if (now - self.last_activity > IDLE_TIMEOUT_MS) {
                // Check if there are active sessions
                if (self.server.session_manager.sessionCount() == 0) break; // No active sessions, shut down
            }

            // Use poll to wait for connections with timeout
            var fds = [_]posix.pollfd{.{
                .fd = sock,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const poll_timeout: i32 = 5000; // 5 second poll intervals
            const poll_result = posix.poll(&fds, poll_timeout) catch continue;

            if (poll_result == 0) {
                if (g_shutdown_requested) break;
                continue; // timeout, loop back to check idle
            }

            if (fds[0].revents & posix.POLL.IN == 0) continue;

            // Accept a connection and authenticate it before reading requests.
            const client_fd = posix.accept(sock, null, null, posix.SOCK.CLOEXEC) catch continue;
            defer posix.close(client_fd);

            ipc_identity.validatePeerUid(client_fd) catch |err| {
                debug_log.log("DaemonServer.run: rejected socket peer: {s}", .{@errorName(err)});
                continue;
            };

            self.last_activity = std.time.milliTimestamp();
            self.handleConnection(client_fd);
        }
    }

    pub fn reapOrphanedSessions(self: *DaemonServer) void {
        self.server.mutex.lock();
        defer self.server.mutex.unlock();
        if (self.server.session_manager.sessionCount() == 0) return;

        const now = std.time.milliTimestamp();

        var ids = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (ids.items) |id| self.allocator.free(id);
            ids.deinit(self.allocator);
        }

        var iter = self.server.session_manager.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.pending_run != null or session.status == .running) {
                debug_log.log("DaemonServer.reapOrphanedSessions: retaining active session_id={s}", .{entry.key_ptr.*});
                continue;
            }

            // Check per-session idle timeout
            if (session.last_activity > 0 and
                now - session.last_activity > self.session_idle_timeout_ms)
            {
                const id_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                ids.append(self.allocator, id_copy) catch {
                    self.allocator.free(id_copy);
                    continue;
                };
                continue;
            }

            // Check orphaned owner process
            if (session.orphan_action == .none) continue;
            const owner_pid = session.owner_pid orelse continue;
            if (!isProcessAlive(owner_pid)) {
                const id_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                ids.append(self.allocator, id_copy) catch {
                    self.allocator.free(id_copy);
                    continue;
                };
            }
        }

        for (ids.items) |id| {
            const session = self.server.session_manager.sessions.get(id) orelse continue;
            const mode: DebugServer.EndMode = switch (session.orphan_action) {
                .detach => .detach,
                .terminate, .none => .terminate,
            };
            debug_log.log("DaemonServer.reapOrphanedSessions: ending session_id={s} mode={s} active={}", .{ id, @tagName(mode), session.pending_run != null });
            const result = self.server.endSessionLocked(self.allocator, id, mode, true) catch |err| {
                debug_log.log("DaemonServer.reapOrphanedSessions: failed session_id={s}: {s}", .{ id, @errorName(err) });
                continue;
            };
            switch (result) {
                .ok => |raw| self.allocator.free(raw),
                .ok_static => {},
                .err => |tool_err| debug_log.log("DaemonServer.reapOrphanedSessions: rejected session_id={s}: {s}", .{ id, tool_err.message }),
            }
        }
    }

    fn isProcessAlive(pid: posix.pid_t) bool {
        posix.kill(pid, 0) catch |err| {
            return switch (err) {
                error.PermissionDenied => true,
                error.ProcessNotFound => false,
                else => true,
            };
        };
        return true;
    }

    fn handleConnection(self: *DaemonServer, client_fd: posix.socket_t) void {
        // Read one JSON line from the client
        var read_buf: [65536]u8 = undefined;
        var total_read: usize = 0;
        var scan_start: usize = 0;

        while (total_read < read_buf.len) {
            const n = posix.read(client_fd, read_buf[total_read..]) catch return;
            if (n == 0) break;
            total_read += n;

            // Only scan newly-read bytes for newline (avoids O(n²) rescan)
            if (std.mem.indexOfScalar(u8, read_buf[scan_start..total_read], '\n') != null) break;
            scan_start = total_read;
        }

        if (total_read == 0) return;

        // Trim trailing newline
        var line = read_buf[0..total_read];
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];

        // Parse the request: {"tool":"debug_launch","args":{...}}
        const parsed = json.parseFromSlice(json.Value, self.allocator, line, .{}) catch {
            self.writeResponse(client_fd, "{\"ok\":false,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            self.writeResponse(client_fd, "{\"ok\":false,\"error\":{\"code\":-32600,\"message\":\"Request must be object\"}}");
            return;
        }

        const tool_val = parsed.value.object.get("tool") orelse {
            self.writeResponse(client_fd, "{\"ok\":false,\"error\":{\"code\":-32602,\"message\":\"Missing tool\"}}");
            return;
        };
        if (tool_val != .string) {
            self.writeResponse(client_fd, "{\"ok\":false,\"error\":{\"code\":-32602,\"message\":\"tool must be string\"}}");
            return;
        }
        const tool_name = tool_val.string;

        const tool_args = parsed.value.object.get("args");

        // Dispatch via McpServer.callTool
        const result = self.server.callTool(self.allocator, tool_name, tool_args) catch {
            self.writeResponse(client_fd, "{\"ok\":false,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}");
            return;
        };

        switch (result) {
            .ok, .ok_static => |raw| {
                defer if (result == .ok) self.allocator.free(raw);
                // Build response: {"ok":true,"result":<raw>}
                var aw: Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                aw.writer.writeAll("{\"ok\":true,\"result\":") catch return;
                aw.writer.writeAll(raw) catch return;
                aw.writer.writeByte('}') catch return;
                const response = aw.toOwnedSlice() catch return;
                defer self.allocator.free(response);
                self.writeResponse(client_fd, response);
            },
            .err => |e| {
                // Build response: {"ok":false,"error":{"code":N,"message":"..."}}
                var aw: Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                var jw: Stringify = .{ .writer = &aw.writer };
                jw.beginObject() catch return;
                jw.objectField("ok") catch return;
                jw.write(false) catch return;
                jw.objectField("error") catch return;
                jw.beginObject() catch return;
                jw.objectField("code") catch return;
                jw.write(e.code) catch return;
                jw.objectField("message") catch return;
                jw.write(e.message) catch return;
                jw.endObject() catch return;
                jw.endObject() catch return;
                const response = aw.toOwnedSlice() catch return;
                defer self.allocator.free(response);
                self.writeResponse(client_fd, response);
            },
        }
    }

    fn writeResponse(self: *DaemonServer, client_fd: posix.socket_t, response: []const u8) void {
        _ = self;
        const iovecs = [_]posix.iovec_const{
            .{ .base = response.ptr, .len = response.len },
            .{ .base = "\n", .len = 1 },
        };
        _ = posix.writev(client_fd, &iovecs) catch {};
    }

    fn writePidFile(self: *DaemonServer) !void {
        const pid_path = try paths.getDaemonPidPath(self.allocator);
        errdefer self.allocator.free(pid_path);

        const c_fns = struct {
            extern fn getpid() posix.pid_t;
        };

        debug_log.log("DaemonServer.writePidFile: securely creating {s}", .{pid_path});
        try ipc_identity.writePidFile(pid_path, c_fns.getpid());
        std.debug.assert(self.pid_path == null);
        self.pid_path = pid_path;
    }
};

test "daemon teardown preserves unsafe socket and removes published PID file" {
    if (@import("builtin").os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "daemon.sock", .data = "not a socket" });
    try tmp.dir.writeFile(.{ .sub_path = "daemon.pid", .data = "123\n" });

    const socket_path = try tmp.dir.realpathAlloc(std.testing.allocator, "daemon.sock");
    defer std.testing.allocator.free(socket_path);
    const pid_path = try tmp.dir.realpathAlloc(std.testing.allocator, "daemon.pid");
    defer std.testing.allocator.free(pid_path);

    var daemon = DaemonServer.init(std.testing.allocator, null);
    daemon.socket_path = try std.testing.allocator.dupe(u8, socket_path);
    daemon.pid_path = try std.testing.allocator.dupe(u8, pid_path);
    daemon.deinit();

    try tmp.dir.access("daemon.sock", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("daemon.pid", .{}));
}

test "daemon teardown releases the socket owner lock" {
    if (@import("builtin").os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const socket_path = try std.fs.path.join(std.testing.allocator, &.{ root, "daemon.sock" });
    defer std.testing.allocator.free(socket_path);

    var daemon = DaemonServer.init(std.testing.allocator, null);
    daemon.socket_owner_lock = try paths.acquireSocketOwnerLock(std.testing.allocator, socket_path);
    daemon.socket_path = try std.testing.allocator.dupe(u8, socket_path);
    daemon.deinit();

    // A successor must be able to take over the path once teardown finished.
    var lock = try paths.acquireSocketOwnerLock(std.testing.allocator, socket_path);
    lock.release();
}

test "reaping a session queues dashboard end until delivery" {
    var daemon = DaemonServer.init(std.testing.allocator, 1);
    defer daemon.deinit();

    var mock = @import("driver.zig").MockDriver{};
    const session_id = try daemon.server.session_manager.createSession(mock.activeDriver(), null, .none);
    const id_copy = try std.testing.allocator.dupe(u8, session_id);
    defer std.testing.allocator.free(id_copy);
    daemon.server.rememberDashboardLaunch(session_id, "/tmp/app", "native", "stopped");
    const session = daemon.server.session_manager.sessions.get(session_id).?;
    session.last_activity = std.time.milliTimestamp() - 100;
    daemon.server.dashboard_available = false;
    daemon.server.dashboard_failure_count = 1;
    daemon.server.last_dashboard_attempt_ms = std.time.milliTimestamp();

    daemon.reapOrphanedSessions();

    try std.testing.expect(daemon.server.session_manager.sessions.get(id_copy) == null);
    try std.testing.expectEqual(@as(usize, 1), daemon.server.dashboard_session_count);
    try std.testing.expect(daemon.server.dashboard_sessions[0].pending_end);
}

// ── Signal Handling ─────────────────────────────────────────────────────

test "orphan reaper preserves sessions with active runs" {
    const allocator = std.testing.allocator;
    var daemon = DaemonServer.init(allocator, 1);
    defer daemon.deinit();

    var mock = @import("driver.zig").MockDriver{};
    mock.setBlockRun(true);
    const session_id = try daemon.server.session_manager.createSession(mock.activeDriver(), null, .terminate);
    const session = daemon.server.session_manager.getSession(session_id).?;
    session.status = .stopped;

    const run_args = try json.parseFromSlice(json.Value, allocator,
        \\{"session_id":"session-1","action":"continue","timeout_ms":0}
    , .{});
    defer run_args.deinit();
    const run_result = try daemon.server.callTool(allocator, "debug_run", run_args.value);
    switch (run_result) {
        .ok => |raw| allocator.free(raw),
        .ok_static => {},
        .err => unreachable,
    }
    mock.waitForRunEntered();

    session.last_activity = std.time.milliTimestamp() - 10;
    daemon.reapOrphanedSessions();

    try std.testing.expectEqual(@as(usize, 1), daemon.server.session_manager.sessionCount());
    try std.testing.expect(session.pending_run != null);
    try std.testing.expect(!mock.terminated);
    try std.testing.expect(!mock.deinitialized);
}

var g_daemon_socket_path: [128]u8 = undefined;
var g_daemon_socket_path_len: usize = 0;
var g_shutdown_requested: bool = false;

fn setupSignalHandler() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = sigHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);

    // Ignore SIGPIPE so that send() to a broken dashboard socket returns
    // EPIPE instead of killing the daemon process.
    const ignore_act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore_act, null);
}

fn sigHandler(_: c_int) callconv(.c) void {
    g_shutdown_requested = true;
}
