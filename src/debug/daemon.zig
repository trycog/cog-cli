const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const server_mod = @import("server.zig");
const DebugServer = server_mod.DebugServer;
const ToolResult = server_mod.ToolResult;

// ── Daemon Server ───────────────────────────────────────────────────────

pub const DaemonServer = struct {
    allocator: std.mem.Allocator,
    server: DebugServer,
    socket_fd: ?posix.socket_t = null,
    last_activity: i64 = 0,

    const IDLE_TIMEOUT_MS: i64 = 5 * 60 * 1000; // 5 minutes

    pub fn init(allocator: std.mem.Allocator) DaemonServer {
        return .{
            .allocator = allocator,
            .server = DebugServer.init(allocator),
            .last_activity = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *DaemonServer) void {
        if (self.socket_fd) |fd| {
            posix.close(fd);
            self.socket_fd = null;
        }
        // Clean up socket and pid files
        var path_buf: [128]u8 = undefined;
        if (getSocketPath(&path_buf)) |path| {
            std.fs.deleteFileAbsolute(path) catch {};
        }
        var pid_buf: [128]u8 = undefined;
        if (getPidPath(&pid_buf)) |path| {
            std.fs.deleteFileAbsolute(path) catch {};
        }
        self.server.deinit();
    }

    pub fn run(self: *DaemonServer) !void {
        // Set up signal handler for clean shutdown
        setupSignalHandler();

        // Connect to dashboard TUI if one is running
        self.server.connectDashboardSocket();

        // Create and bind the Unix domain socket
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        var path_buf: [128]u8 = undefined;
        const sock_path = getSocketPath(&path_buf) orelse return error.PathTooLong;

        // Remove stale socket if it exists
        std.fs.deleteFileAbsolute(sock_path) catch {};

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..sock_path.len], sock_path);

        try posix.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(sock, 8);

        self.socket_fd = sock;

        // Write PID file
        self.writePidFile() catch {};

        // Store socket path for signal handler cleanup
        @memcpy(g_daemon_socket_path[0..sock_path.len], sock_path);
        g_daemon_socket_path_len = sock_path.len;

        // Accept loop with idle timeout
        while (true) {
            // Check idle timeout
            const now = std.time.milliTimestamp();
            if (now - self.last_activity > IDLE_TIMEOUT_MS) {
                // Check if there are active sessions
                const sessions = self.server.session_manager.listSessions(self.allocator) catch break;
                defer self.allocator.free(sessions);
                if (sessions.len == 0) break; // No active sessions, shut down
            }

            // Use poll to wait for connections with timeout
            var fds = [_]posix.pollfd{.{
                .fd = sock,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const poll_timeout: i32 = 5000; // 5 second poll intervals
            const poll_result = posix.poll(&fds, poll_timeout) catch continue;

            if (poll_result == 0) continue; // timeout, loop back to check idle

            if (fds[0].revents & posix.POLL.IN == 0) continue;

            // Accept a connection
            const client_fd = posix.accept(sock, null, null, 0) catch continue;
            defer posix.close(client_fd);

            self.last_activity = std.time.milliTimestamp();
            self.handleConnection(client_fd);
        }
    }

    fn handleConnection(self: *DaemonServer, client_fd: posix.socket_t) void {
        // Read one JSON line from the client
        var read_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < read_buf.len) {
            const n = posix.read(client_fd, read_buf[total_read..]) catch return;
            if (n == 0) break;
            total_read += n;

            // Check if we have a complete line
            if (std.mem.indexOfScalar(u8, read_buf[0..total_read], '\n') != null) break;
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
            .ok => |raw| {
                defer self.allocator.free(raw);
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
        _ = posix.write(client_fd, response) catch {};
        _ = posix.write(client_fd, "\n") catch {};
    }

    fn writePidFile(self: *DaemonServer) !void {
        _ = self;
        var pid_buf: [128]u8 = undefined;
        const pid_path = getPidPath(&pid_buf) orelse return error.PathTooLong;

        var f = try std.fs.createFileAbsolute(pid_path, .{});
        defer f.close();

        var buf: [32]u8 = undefined;
        const c_fns = struct {
            extern fn getpid() i32;
        };
        const s = std.fmt.bufPrint(&buf, "{d}", .{c_fns.getpid()}) catch return;
        var write_buf: [64]u8 = undefined;
        var w = f.writer(&write_buf);
        w.interface.writeAll(s) catch {};
        w.interface.flush() catch {};
    }
};

// ── Socket / PID Path Helpers ───────────────────────────────────────────

fn getUid() u32 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        return std.os.linux.getuid();
    } else if (builtin.os.tag == .macos) {
        return getMacosUid();
    } else {
        return 0;
    }
}

fn getMacosUid() u32 {
    const c_fns = struct {
        extern fn getuid() u32;
    };
    return c_fns.getuid();
}

pub fn getSocketPath(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/cog-debug-{d}.sock", .{getUid()}) catch null;
}

pub fn getPidPath(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/cog-debug-{d}.pid", .{getUid()}) catch null;
}

// ── Signal Handling ─────────────────────────────────────────────────────

var g_daemon_socket_path: [128]u8 = undefined;
var g_daemon_socket_path_len: usize = 0;

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
    // Clean up socket file
    if (g_daemon_socket_path_len > 0) {
        const path = g_daemon_socket_path[0..g_daemon_socket_path_len];
        std.fs.deleteFileAbsolute(path) catch {};
    }
    // Clean up pid file
    var pid_buf: [128]u8 = undefined;
    if (getPidPath(&pid_buf)) |path| {
        std.fs.deleteFileAbsolute(path) catch {};
    }
    std.process.exit(0);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "getSocketPath returns valid path" {
    var buf: [128]u8 = undefined;
    const path = getSocketPath(&buf);
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.startsWith(u8, path.?, "/tmp/cog-debug-"));
    try std.testing.expect(std.mem.endsWith(u8, path.?, ".sock"));
}

test "getPidPath returns valid path" {
    var buf: [128]u8 = undefined;
    const path = getPidPath(&buf);
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.startsWith(u8, path.?, "/tmp/cog-debug-"));
    try std.testing.expect(std.mem.endsWith(u8, path.?, ".pid"));
}
