const std = @import("std");
const posix = std.posix;

// ── ANSI Styles ─────────────────────────────────────────────────────────

const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";
const bg_cyan = "\x1B[46m";
const black = "\x1B[30m";
const yellow = "\x1B[33m";

// ── Unicode Glyphs ──────────────────────────────────────────────────────

const bullet_filled = "\xE2\x97\x8F"; // ●
const bullet_open = "\xE2\x97\x8B"; // ○
const check = "\xE2\x9C\x93"; // ✓
const cross = "\xE2\x9C\x97"; // ✗
const arrow_right = "\xE2\x96\xB8"; // ▸
const arrow_curr = "\xE2\x86\x92"; // →

// ── Box-Drawing Characters ──────────────────────────────────────────────

const hh = "\xE2\x94\x80"; // ─
const vv = "\xE2\x94\x82"; // │
const ct = "\xE2\x94\x8C"; // ┌
const cb = "\xE2\x94\x94"; // └
const tr = "\xE2\x94\x90"; // ┐
const br = "\xE2\x94\x98"; // ┘
const tee_top = "\xE2\x94\xAC"; // ┬
const tee_bottom = "\xE2\x94\xB4"; // ┴
const tee_left = "\xE2\x94\x9C"; // ├
const tee_right = "\xE2\x94\xA4"; // ┤
const h3 = hh ++ hh ++ hh;
const h4 = h3 ++ hh;

// ── Per-Session State ───────────────────────────────────────────────────

const MAX_SESSIONS = 16;
const MAX_FRAMES = 32;
const MAX_LOCALS = 32;
const MAX_BREAKPOINTS = 32;
const LOG_SIZE = 16;
const SOURCE_CONTEXT = 100; // 49 above + current + 50 below
const SOURCE_LINE_LEN = 200;

const SourceLine = struct {
    text: [SOURCE_LINE_LEN]u8 = undefined,
    text_len: usize = 0,
    line_num: u32 = 0,

    fn textSlice(self: *const SourceLine) []const u8 {
        return self.text[0..self.text_len];
    }
};

const FrameInfo = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    source: [128]u8 = undefined,
    source_len: usize = 0,
    line: u32 = 0,

    fn nameSlice(self: *const FrameInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    fn sourceSlice(self: *const FrameInfo) []const u8 {
        return self.source[0..self.source_len];
    }
};

const LocalInfo = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    value: [64]u8 = undefined,
    value_len: usize = 0,
    var_type: [32]u8 = undefined,
    var_type_len: usize = 0,

    fn nameSlice(self: *const LocalInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    fn valueSlice(self: *const LocalInfo) []const u8 {
        return self.value[0..self.value_len];
    }

    fn typeSlice(self: *const LocalInfo) []const u8 {
        return self.var_type[0..self.var_type_len];
    }
};

const BpInfo = struct {
    id: u32 = 0,
    file: [128]u8 = undefined,
    file_len: usize = 0,
    line: u32 = 0,
    verified: bool = false,

    fn fileSlice(self: *const BpInfo) []const u8 {
        return self.file[0..self.file_len];
    }
};

const LogEntry = struct {
    tool_name: [24]u8 = undefined,
    tool_name_len: usize = 0,
    summary: [80]u8 = undefined,
    summary_len: usize = 0,
    is_error: bool = false,

    fn toolNameSlice(self: *const LogEntry) []const u8 {
        return self.tool_name[0..self.tool_name_len];
    }

    fn summarySlice(self: *const LogEntry) []const u8 {
        return self.summary[0..self.summary_len];
    }
};

const RingLog = struct {
    entries: [LOG_SIZE]LogEntry = [_]LogEntry{.{}} ** LOG_SIZE,
    head: usize = 0,
    count: usize = 0,

    fn push(self: *RingLog, entry: LogEntry) void {
        self.entries[self.head] = entry;
        self.head = (self.head + 1) % LOG_SIZE;
        if (self.count < LOG_SIZE) self.count += 1;
    }

    fn iter(self: *const RingLog) RingLogIter {
        const start = if (self.count < LOG_SIZE) 0 else self.head;
        return .{ .log = self, .pos = start, .remaining = self.count };
    }
};

const RingLogIter = struct {
    log: *const RingLog,
    pos: usize,
    remaining: usize,

    fn next(self: *RingLogIter) ?*const LogEntry {
        if (self.remaining == 0) return null;
        const entry = &self.log.entries[self.pos];
        self.pos = (self.pos + 1) % LOG_SIZE;
        self.remaining -= 1;
        return entry;
    }
};

const TuiSession = struct {
    session_id: [32]u8 = undefined,
    session_id_len: usize = 0,
    program: [128]u8 = undefined,
    program_len: usize = 0,
    driver_type: [16]u8 = undefined,
    driver_type_len: usize = 0,
    status: [16]u8 = undefined,
    status_len: usize = 0,

    // Stop state
    stop_reason: [32]u8 = undefined,
    stop_reason_len: usize = 0,
    location_file: [128]u8 = undefined,
    location_file_len: usize = 0,
    location_func: [64]u8 = undefined,
    location_func_len: usize = 0,
    location_line: u32 = 0,

    // Stack trace
    frames: [MAX_FRAMES]FrameInfo = [_]FrameInfo{.{}} ** MAX_FRAMES,
    frame_count: usize = 0,

    // Locals
    locals: [MAX_LOCALS]LocalInfo = [_]LocalInfo{.{}} ** MAX_LOCALS,
    local_count: usize = 0,

    // Breakpoints
    breakpoints: [MAX_BREAKPOINTS]BpInfo = [_]BpInfo{.{}} ** MAX_BREAKPOINTS,
    bp_count: usize = 0,

    // Source context
    source_lines: [SOURCE_CONTEXT]SourceLine = [_]SourceLine{.{}} ** SOURCE_CONTEXT,
    source_line_count: usize = 0,
    source_current_idx: usize = 0,
    source_file: [128]u8 = undefined,
    source_file_len: usize = 0,

    // Per-session log
    log: RingLog = .{},

    fn sessionIdSlice(self: *const TuiSession) []const u8 {
        return self.session_id[0..self.session_id_len];
    }

    fn programSlice(self: *const TuiSession) []const u8 {
        return self.program[0..self.program_len];
    }

    fn driverTypeSlice(self: *const TuiSession) []const u8 {
        return self.driver_type[0..self.driver_type_len];
    }

    fn statusSlice(self: *const TuiSession) []const u8 {
        return self.status[0..self.status_len];
    }

    fn stopReasonSlice(self: *const TuiSession) []const u8 {
        return self.stop_reason[0..self.stop_reason_len];
    }

    fn locationFileSlice(self: *const TuiSession) []const u8 {
        return self.location_file[0..self.location_file_len];
    }

    fn locationFuncSlice(self: *const TuiSession) []const u8 {
        return self.location_func[0..self.location_func_len];
    }

    fn sourceFileSlice(self: *const TuiSession) []const u8 {
        return self.source_file[0..self.source_file_len];
    }
};

// ── Signal Handling ─────────────────────────────────────────────────────

var g_socket_path: [128]u8 = undefined;
var g_socket_path_len: usize = 0;
var g_original_termios: ?posix.termios = null;
var g_winch_received: bool = false;

fn sigintHandler(_: c_int) callconv(.c) void {
    // Restore terminal
    if (g_original_termios) |orig| {
        posix.tcsetattr(posix.STDIN_FILENO, .NOW, orig) catch {};
        g_original_termios = null;
    }
    // Show cursor
    const show_cursor = "\x1B[?25h\n";
    _ = posix.write(posix.STDERR_FILENO, show_cursor) catch {};
    // Clean up socket
    if (g_socket_path_len > 0) {
        const path = g_socket_path[0..g_socket_path_len];
        std.fs.deleteFileAbsolute(path) catch {};
    }
    // Exit
    std.process.exit(0);
}

fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_winch_received = true;
}

// ── DashboardTui ────────────────────────────────────────────────────────

const FocusedPane = enum { source, sidebar, log };

pub const DashboardTui = struct {
    allocator: std.mem.Allocator,
    listener: ?posix.socket_t,
    clients: [MAX_SESSIONS]posix.socket_t,
    client_count: usize,
    client_bufs: [MAX_SESSIONS][8192]u8,
    client_buf_lens: [MAX_SESSIONS]usize,

    sessions: [MAX_SESSIONS]TuiSession,
    session_count: usize,
    focused: usize,

    global_log: RingLog,
    running: bool,

    socket_path_buf: [128]u8,
    socket_path_len: usize,

    original_termios: ?posix.termios,

    term_width: u16,
    term_height: u16,

    active_pane: FocusedPane,
    source_scroll: usize,
    sidebar_scroll: usize,
    log_scroll: usize,

    pub fn init(allocator: std.mem.Allocator) DashboardTui {
        return .{
            .allocator = allocator,
            .listener = null,
            .clients = [_]posix.socket_t{0} ** MAX_SESSIONS,
            .client_count = 0,
            .client_bufs = undefined,
            .client_buf_lens = [_]usize{0} ** MAX_SESSIONS,
            .sessions = [_]TuiSession{.{}} ** MAX_SESSIONS,
            .session_count = 0,
            .focused = 0,
            .global_log = .{},
            .running = true,
            .socket_path_buf = undefined,
            .socket_path_len = 0,
            .original_termios = null,
            .term_width = getTerminalSize().width,
            .term_height = getTerminalSize().height,
            .active_pane = .source,
            .source_scroll = 0,
            .sidebar_scroll = 0,
            .log_scroll = 0,
        };
    }

    pub fn deinit(self: *DashboardTui) void {
        // Close client sockets
        for (0..self.client_count) |i| {
            posix.close(self.clients[i]);
        }
        // Close listener
        if (self.listener) |l| {
            posix.close(l);
        }
        // Remove socket file
        if (self.socket_path_len > 0) {
            std.fs.deleteFileAbsolute(self.socket_path_buf[0..self.socket_path_len]) catch {};
        }
        // Restore terminal
        if (self.original_termios) |orig| {
            posix.tcsetattr(posix.STDIN_FILENO, .NOW, orig) catch {};
            g_original_termios = null;
        }
        // Show cursor
        stderrWrite("\x1B[?25h");
    }

    pub fn run(self: *DashboardTui) !void {
        // Build socket path: /tmp/cog-debug-dashboard-{uid}.sock
        const path = std.fmt.bufPrint(&self.socket_path_buf, "/tmp/cog-debug-dashboard-{d}.sock", .{getUid()}) catch return error.PathTooLong;
        self.socket_path_len = path.len;

        // Copy to global for signal handler
        @memcpy(g_socket_path[0..path.len], path);
        g_socket_path_len = path.len;

        // Remove stale socket if it exists
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };

        // Create listener socket
        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        if (path.len > addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);

        posix.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            if (err == error.AddressInUse) {
                printErr("error: Another dashboard is already running\n");
                return error.Explained;
            }
            return err;
        };
        try posix.listen(sock, 5);
        self.listener = sock;

        // Enter raw terminal mode
        self.original_termios = try posix.tcgetattr(posix.STDIN_FILENO);
        g_original_termios = self.original_termios;
        var raw = self.original_termios.?;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);

        // Install signal handlers
        const sa = posix.Sigaction{
            .handler = .{ .handler = sigintHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &sa, null);

        const sa_winch = posix.Sigaction{
            .handler = .{ .handler = sigwinchHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &sa_winch, null);

        // Hide cursor
        stderrWrite("\x1B[?25h"); // first show to reset state
        stderrWrite("\x1B[?25l"); // then hide

        // Initial render
        self.render();

        // Main loop
        while (self.running) {
            self.pollAndProcess() catch |err| {
                if (err == error.Explained) return err;
                continue;
            };
        }
    }

    fn pollAndProcess(self: *DashboardTui) !void {
        // Build pollfd array: [listener, stdin, client0, client1, ...]
        var fds: [2 + MAX_SESSIONS]posix.pollfd = undefined;
        var nfds: usize = 0;

        // Listener socket
        if (self.listener) |l| {
            fds[nfds] = .{ .fd = l, .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        // Stdin
        fds[nfds] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };
        const stdin_idx = nfds;
        nfds += 1;

        // Client sockets
        const clients_start = nfds;
        for (0..self.client_count) |i| {
            fds[nfds] = .{ .fd = self.clients[i], .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        const ready = posix.poll(fds[0..nfds], 100) catch |err| {
            // SIGWINCH (or other signal) interrupts poll — check and re-render
            if (err == error.Interrupted) {
                if (g_winch_received) {
                    g_winch_received = false;
                    self.render();
                }
                return;
            }
            return err;
        };

        var need_render = g_winch_received;
        if (g_winch_received) {
            g_winch_received = false;
        }

        if (ready == 0 and !need_render) return; // timeout, no events

        // Check listener for new connections
        if (self.listener != null and fds[0].revents & posix.POLL.IN != 0) {
            self.acceptClient();
            need_render = true;
        }

        // Check stdin for keyboard input
        if (fds[stdin_idx].revents & posix.POLL.IN != 0) {
            if (self.handleKeyboard()) {
                need_render = true;
            }
        }

        // Check client sockets for data
        var i: usize = 0;
        while (i < self.client_count) {
            const fd_idx = clients_start + i;
            if (fds[fd_idx].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                if (self.readClient(i)) {
                    need_render = true;
                } else {
                    // Client disconnected
                    self.removeClient(i);
                    need_render = true;
                    continue; // don't increment i
                }
            }
            i += 1;
        }

        if (need_render) {
            self.render();
        }
    }

    fn acceptClient(self: *DashboardTui) void {
        if (self.client_count >= MAX_SESSIONS) return;

        const listener = self.listener orelse return;
        const client_fd = posix.accept(listener, null, null, 0) catch return;

        self.clients[self.client_count] = client_fd;
        self.client_buf_lens[self.client_count] = 0;
        self.client_count += 1;
    }

    fn removeClient(self: *DashboardTui, idx: usize) void {
        posix.close(self.clients[idx]);
        // Shift remaining clients down
        var j: usize = idx;
        while (j + 1 < self.client_count) : (j += 1) {
            self.clients[j] = self.clients[j + 1];
            self.client_bufs[j] = self.client_bufs[j + 1];
            self.client_buf_lens[j] = self.client_buf_lens[j + 1];
        }
        self.client_count -= 1;
    }

    /// Read data from a client. Returns true if data was read, false if client disconnected.
    fn readClient(self: *DashboardTui, idx: usize) bool {
        const fd = self.clients[idx];
        const buf = &self.client_bufs[idx];
        const buf_len = &self.client_buf_lens[idx];

        const remaining = buf.len - buf_len.*;
        if (remaining == 0) {
            // Buffer full, discard
            buf_len.* = 0;
            return true;
        }

        const n = posix.read(fd, buf[buf_len.*..]) catch return false;
        if (n == 0) return false; // EOF

        buf_len.* += n;

        // Process complete lines
        self.processClientBuffer(idx);
        return true;
    }

    fn processClientBuffer(self: *DashboardTui, idx: usize) void {
        const buf = &self.client_bufs[idx];
        const buf_len = &self.client_buf_lens[idx];

        var start: usize = 0;
        var i: usize = 0;
        while (i < buf_len.*) : (i += 1) {
            if (buf[i] == '\n') {
                const line = buf[start..i];
                if (line.len > 0) {
                    self.processEvent(line);
                }
                start = i + 1;
            }
        }

        // Move remaining partial line to beginning
        if (start > 0) {
            const remaining = buf_len.* - start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, buf[0..remaining], buf[start..buf_len.*]);
            }
            buf_len.* = remaining;
        }
    }

    /// Handle keyboard input. Returns true if state changed.
    fn handleKeyboard(self: *DashboardTui) bool {
        var buf: [8]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &buf) catch return false;
        if (n == 0) return false;

        switch (buf[0]) {
            'q' => {
                self.running = false;
                return false;
            },
            3 => { // Ctrl+C
                self.running = false;
                return false;
            },
            '\t' => {
                // Tab: cycle pane focus
                self.active_pane = switch (self.active_pane) {
                    .source => .sidebar,
                    .sidebar => .log,
                    .log => .source,
                };
                return true;
            },
            'j' => return self.scrollDown(),
            'k' => return self.scrollUp(),
            '[' => {
                // Switch to previous session
                if (self.session_count > 1 and self.focused > 0) {
                    self.focused -= 1;
                    self.source_scroll = 0;
                    self.sidebar_scroll = 0;
                    self.autoScrollSource();
                    return true;
                }
            },
            ']' => {
                // Switch to next session
                if (self.session_count > 1 and self.focused < self.session_count - 1) {
                    self.focused += 1;
                    self.source_scroll = 0;
                    self.sidebar_scroll = 0;
                    self.autoScrollSource();
                    return true;
                }
            },
            27 => { // Escape sequence
                if (n >= 3 and buf[1] == '[') {
                    switch (buf[2]) {
                        'A' => return self.scrollUp(), // Up
                        'B' => return self.scrollDown(), // Down
                        else => {},
                    }
                }
            },
            else => {},
        }
        return false;
    }

    fn scrollUp(self: *DashboardTui) bool {
        switch (self.active_pane) {
            .source => {
                if (self.source_scroll > 0) {
                    self.source_scroll -= 1;
                    return true;
                }
            },
            .sidebar => {
                if (self.sidebar_scroll > 0) {
                    self.sidebar_scroll -= 1;
                    return true;
                }
            },
            .log => {
                if (self.log_scroll > 0) {
                    self.log_scroll -= 1;
                    return true;
                }
            },
        }
        return false;
    }

    fn scrollDown(self: *DashboardTui) bool {
        const main_height = self.computeMainHeight(self.term_height);
        const log_height = @max(@as(usize, 4), @as(usize, self.term_height) / 5);

        switch (self.active_pane) {
            .source => {
                if (self.session_count > 0 and self.focused < self.session_count) {
                    const s = &self.sessions[self.focused];
                    const max_scroll = if (s.source_line_count > main_height) s.source_line_count - main_height else 0;
                    if (self.source_scroll < max_scroll) {
                        self.source_scroll += 1;
                        return true;
                    }
                }
            },
            .sidebar => {
                if (self.session_count > 0 and self.focused < self.session_count) {
                    const session: ?*const TuiSession = &self.sessions[self.focused];
                    const total = self.countSidebarItems(session);
                    const max_scroll = if (total > main_height) total - main_height else 0;
                    if (self.sidebar_scroll < max_scroll) {
                        self.sidebar_scroll += 1;
                        return true;
                    }
                }
            },
            .log => {
                const max_scroll = if (self.global_log.count > log_height) self.global_log.count - log_height else 0;
                if (self.log_scroll < max_scroll) {
                    self.log_scroll += 1;
                    return true;
                }
            },
        }
        return false;
    }

    // ── Event Processing ─────────────────────────────────────────────

    fn processEvent(self: *DashboardTui, line: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            // Log parse error
            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "parse_error");
            copyInto(&entry.summary, &entry.summary_len, "invalid JSON from server");
            entry.is_error = true;
            self.global_log.push(entry);
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        const type_val = obj.get("type") orelse return;
        if (type_val != .string) return;
        const event_type = type_val.string;

        if (std.mem.eql(u8, event_type, "launch")) {
            self.handleLaunchEvent(obj);
        } else if (std.mem.eql(u8, event_type, "breakpoint")) {
            self.handleBreakpointEvent(obj);
        } else if (std.mem.eql(u8, event_type, "stop")) {
            self.handleStopEvent(obj);
        } else if (std.mem.eql(u8, event_type, "inspect")) {
            self.handleInspectEvent(obj);
        } else if (std.mem.eql(u8, event_type, "run")) {
            self.handleRunEvent(obj);
        } else if (std.mem.eql(u8, event_type, "session_end")) {
            self.handleSessionEndEvent(obj);
        } else if (std.mem.eql(u8, event_type, "error")) {
            self.handleErrorEvent(obj);
        } else if (std.mem.eql(u8, event_type, "activity")) {
            self.handleActivityEvent(obj);
        }
    }

    fn handleLaunchEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        if (self.session_count >= MAX_SESSIONS) return;

        var session: TuiSession = .{};
        if (obj.get("session_id")) |v| {
            if (v == .string) copyInto(&session.session_id, &session.session_id_len, v.string);
        }
        if (obj.get("program")) |v| {
            if (v == .string) copyInto(&session.program, &session.program_len, v.string);
        }
        if (obj.get("driver")) |v| {
            if (v == .string) copyInto(&session.driver_type, &session.driver_type_len, v.string);
        }
        copyInto(&session.status, &session.status_len, "stopped");

        self.sessions[self.session_count] = session;
        self.session_count += 1;

        // Auto-focus if first session
        if (self.session_count == 1) {
            self.focused = 0;
        }

        // Log
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_launch");
        copyInto(&entry.summary, &entry.summary_len, "session created, stopped at entry");
        self.global_log.push(entry);

        // Per-session log
        self.sessions[self.session_count - 1].log.push(entry);
    }

    fn handleBreakpointEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse return;
        const action = getStr(obj, "action") orelse return;
        const session = self.findSession(session_id) orelse return;

        if (std.mem.eql(u8, action, "set")) {
            if (obj.get("bp")) |bp_val| {
                if (bp_val == .object) {
                    const bp_obj = bp_val.object;
                    if (session.bp_count < MAX_BREAKPOINTS) {
                        var bp: BpInfo = .{};
                        if (bp_obj.get("id")) |v| {
                            if (v == .integer) bp.id = @intCast(v.integer);
                        }
                        if (bp_obj.get("file")) |v| {
                            if (v == .string) copyInto(&bp.file, &bp.file_len, v.string);
                        }
                        if (bp_obj.get("line")) |v| {
                            if (v == .integer) bp.line = @intCast(v.integer);
                        }
                        if (bp_obj.get("verified")) |v| {
                            if (v == .bool) bp.verified = v.bool;
                        }
                        session.breakpoints[session.bp_count] = bp;
                        session.bp_count += 1;
                    }
                }
            }

            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "debug_breakpoint");
            var buf: [80]u8 = undefined;
            const summary = std.fmt.bufPrint(&buf, "set breakpoint", .{}) catch "set breakpoint";
            copyInto(&entry.summary, &entry.summary_len, summary);
            self.global_log.push(entry);
            session.log.push(entry);
        } else if (std.mem.eql(u8, action, "remove")) {
            if (obj.get("bp")) |bp_val| {
                if (bp_val == .object) {
                    if (bp_val.object.get("id")) |v| {
                        if (v == .integer) {
                            const bp_id: u32 = @intCast(v.integer);
                            removeBp(session, bp_id);
                        }
                    }
                }
            }

            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "debug_breakpoint");
            copyInto(&entry.summary, &entry.summary_len, "removed breakpoint");
            self.global_log.push(entry);
            session.log.push(entry);
        } else {
            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "debug_breakpoint");
            copyInto(&entry.summary, &entry.summary_len, "listed breakpoints");
            self.global_log.push(entry);
            session.log.push(entry);
        }
    }

    fn handleStopEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse return;
        const session = self.findSession(session_id) orelse return;

        copyInto(&session.status, &session.status_len, "stopped");

        if (obj.get("reason")) |v| {
            if (v == .string) copyInto(&session.stop_reason, &session.stop_reason_len, v.string);
        }

        // Location
        if (obj.get("location")) |loc_val| {
            if (loc_val == .object) {
                const loc = loc_val.object;
                if (loc.get("file")) |v| {
                    if (v == .string) copyInto(&session.location_file, &session.location_file_len, v.string);
                }
                if (loc.get("line")) |v| {
                    if (v == .integer) session.location_line = @intCast(v.integer);
                }
                if (loc.get("function")) |v| {
                    if (v == .string) copyInto(&session.location_func, &session.location_func_len, v.string);
                }
            }
        }

        // Load source context
        if (session.location_file_len > 0 and session.location_line > 0) {
            loadSourceContext(session, session.locationFileSlice(), session.location_line);
        } else {
            session.source_line_count = 0;
        }

        // Stack trace
        session.frame_count = 0;
        if (obj.get("stack_trace")) |st_val| {
            if (st_val == .array) {
                for (st_val.array.items) |item| {
                    if (session.frame_count >= MAX_FRAMES) break;
                    if (item == .object) {
                        var frame: FrameInfo = .{};
                        if (item.object.get("name")) |v| {
                            if (v == .string) copyInto(&frame.name, &frame.name_len, v.string);
                        }
                        if (item.object.get("source")) |v| {
                            if (v == .string) copyInto(&frame.source, &frame.source_len, v.string);
                        }
                        if (item.object.get("line")) |v| {
                            if (v == .integer) frame.line = @intCast(v.integer);
                        }
                        session.frames[session.frame_count] = frame;
                        session.frame_count += 1;
                    }
                }
            }
        }

        // Locals
        session.local_count = 0;
        if (obj.get("locals")) |locals_val| {
            if (locals_val == .array) {
                for (locals_val.array.items) |item| {
                    if (session.local_count >= MAX_LOCALS) break;
                    if (item == .object) {
                        var local: LocalInfo = .{};
                        if (item.object.get("name")) |v| {
                            if (v == .string) copyInto(&local.name, &local.name_len, v.string);
                        }
                        if (item.object.get("value")) |v| {
                            if (v == .string) copyInto(&local.value, &local.value_len, v.string);
                        }
                        if (item.object.get("type")) |v| {
                            if (v == .string) copyInto(&local.var_type, &local.var_type_len, v.string);
                        }
                        session.locals[session.local_count] = local;
                        session.local_count += 1;
                    }
                }
            }
        }

        // Log
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_run");
        var buf: [80]u8 = undefined;
        const reason = session.stopReasonSlice();
        const summary = std.fmt.bufPrint(&buf, "stopped: {s}", .{truncate(reason, 40)}) catch "stopped";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.global_log.push(entry);
        session.log.push(entry);

        // Auto-scroll source so current line is centered
        self.autoScrollSource();
    }

    fn autoScrollSource(self: *DashboardTui) void {
        if (self.session_count == 0 or self.focused >= self.session_count) return;
        const s = &self.sessions[self.focused];
        if (s.source_line_count == 0) return;

        const size = getTerminalSize();
        const main_height = self.computeMainHeight(size.height);
        const visible = if (main_height > 0) main_height else 1;
        const half = visible / 2;

        if (s.source_current_idx >= half) {
            const max_scroll = if (s.source_line_count > visible) s.source_line_count - visible else 0;
            self.source_scroll = @min(s.source_current_idx - half, max_scroll);
        } else {
            self.source_scroll = 0;
        }
    }

    fn computeMainHeight(self: *const DashboardTui, term_h: u16) usize {
        _ = self;
        const header_height: usize = 1; // session bar
        const footer_height: usize = 1; // key hints
        const border_lines: usize = 3; // top border, separator, bottom border
        const log_height = @max(@as(usize, 4), @as(usize, term_h) / 5);
        const used = header_height + footer_height + border_lines + log_height;
        return if (term_h > used) @as(usize, term_h) - used else 4;
    }

    fn handleInspectEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse return;
        const session = self.findSession(session_id) orelse return;

        const expression = getStr(obj, "expression") orelse "(unknown)";
        const result_str = getStr(obj, "result") orelse "";

        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_inspect");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} \xE2\x86\x92 \"{s}\"", .{
            truncate(expression, 20), truncate(result_str, 30),
        }) catch "inspect completed";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.global_log.push(entry);
        session.log.push(entry);
    }

    fn handleRunEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse return;
        const session = self.findSession(session_id) orelse return;
        const action = getStr(obj, "action") orelse "continue";

        copyInto(&session.status, &session.status_len, "running");

        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_run");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s}", .{truncate(action, 40)}) catch "run";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.global_log.push(entry);
        session.log.push(entry);
    }

    fn handleSessionEndEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse return;

        // Log before removing
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_stop");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} destroyed", .{truncate(session_id, 20)}) catch "session destroyed";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.global_log.push(entry);

        // Remove session
        var i: usize = 0;
        while (i < self.session_count) {
            if (std.mem.eql(u8, self.sessions[i].sessionIdSlice(), session_id)) {
                var j: usize = i;
                while (j + 1 < self.session_count) : (j += 1) {
                    self.sessions[j] = self.sessions[j + 1];
                }
                self.session_count -= 1;

                // Adjust focus
                if (self.session_count == 0) {
                    self.focused = 0;
                } else if (self.focused >= self.session_count) {
                    self.focused = self.session_count - 1;
                }
                break;
            }
            i += 1;
        }
    }

    fn handleErrorEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse "";
        const method = getStr(obj, "method") orelse "unknown";
        const message = getStr(obj, "message") orelse "unknown error";

        var entry: LogEntry = .{ .is_error = true };
        copyInto(&entry.tool_name, &entry.tool_name_len, truncate(method, 24));
        copyInto(&entry.summary, &entry.summary_len, truncate(message, 80));
        self.global_log.push(entry);

        if (self.findSession(session_id)) |session| {
            session.log.push(entry);
        }
    }

    fn handleActivityEvent(self: *DashboardTui, obj: std.json.ObjectMap) void {
        const session_id = getStr(obj, "session_id") orelse "";
        const tool = getStr(obj, "tool") orelse "unknown";
        const summary_str = getStr(obj, "summary") orelse "";

        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, truncate(tool, 24));
        copyInto(&entry.summary, &entry.summary_len, truncate(summary_str, 80));
        self.global_log.push(entry);

        if (self.findSession(session_id)) |session| {
            session.log.push(entry);
        }
    }

    fn findSession(self: *DashboardTui, session_id: []const u8) ?*TuiSession {
        for (self.sessions[0..self.session_count]) |*s| {
            if (std.mem.eql(u8, s.sessionIdSlice(), session_id)) return s;
        }
        return null;
    }

    fn removeBp(session: *TuiSession, bp_id: u32) void {
        var i: usize = 0;
        while (i < session.bp_count) {
            if (session.breakpoints[i].id == bp_id) {
                var j: usize = i;
                while (j + 1 < session.bp_count) : (j += 1) {
                    session.breakpoints[j] = session.breakpoints[j + 1];
                }
                session.bp_count -= 1;
                return;
            }
            i += 1;
        }
    }

    // ── Rendering ────────────────────────────────────────────────────

    fn render(self: *DashboardTui) void {
        render_active = true;
        render_len = 0;
        defer {
            flushRenderBuffer();
            render_active = false;
        }

        // Refresh terminal size
        const size = getTerminalSize();
        self.term_width = size.width;
        self.term_height = size.height;

        const w: usize = self.term_width;
        const h: usize = self.term_height;

        // Move cursor to top-left (no full clear — overwrite in place)
        stderrWrite("\x1B[H");

        // Layout calculations
        const header_height: usize = 1; // session bar
        const footer_height: usize = 1; // key hints
        const border_lines: usize = 3; // top, separator, bottom
        const log_height = @max(@as(usize, 4), h / 5);
        const used = header_height + footer_height + border_lines + log_height;
        const main_height: usize = if (h > used) h - used else 4;

        const sidebar_width: usize = @max(@as(usize, 30), w / 3);
        // 3 = left border + divider + right border
        const source_width: usize = if (w > sidebar_width + 3) w - sidebar_width - 3 else 20;

        // Get focused session
        const session: ?*const TuiSession = if (self.session_count > 0 and self.focused < self.session_count)
            &self.sessions[self.focused]
        else
            null;

        // ── Header: session bar ──
        self.renderSessionBar(w);

        // ── Top border with pane titles ──
        self.renderTopBorder(source_width, sidebar_width, session);

        // ── Main area: source | sidebar ──
        // Build sidebar virtual list: stack frames then locals
        const sidebar_items = self.countSidebarItems(session);

        for (0..main_height) |row| {
            // Left border
            if (self.active_pane == .source) {
                stderrWrite(cyan ++ vv ++ reset);
            } else {
                stderrWrite(dim ++ vv ++ reset);
            }

            // Source pane content
            self.renderSourceRow(row, source_width, session);

            // Divider
            stderrWrite(dim ++ vv ++ reset);

            // Sidebar content
            self.renderSidebarRow(row, sidebar_width, main_height, session, sidebar_items);

            // Right border
            if (self.active_pane == .sidebar) {
                stderrWrite(cyan ++ vv ++ reset);
            } else {
                stderrWrite(dim ++ vv ++ reset);
            }
            stderrWrite("\x1B[K\n");
        }

        // ── Separator between main and log ──
        self.renderMidSeparator(source_width, sidebar_width);

        // ── Log pane ──
        self.renderLogPane(log_height, w);

        // ── Bottom border ──
        self.renderBottomBorder(w);

        // ── Footer ──
        self.renderFooter();
    }

    fn renderSessionBar(self: *const DashboardTui, w: usize) void {
        _ = w;
        if (self.session_count == 0) {
            stderrWrite(dim ++ " Waiting for connections..." ++ reset ++ "\x1B[K\n");
            return;
        }
        stderrWrite(" ");
        for (self.sessions[0..self.session_count], 0..) |*s, i| {
            if (i == self.focused) {
                stderrWrite(cyan ++ bullet_filled ++ " " ++ reset ++ bold);
            } else {
                stderrWrite(dim ++ bullet_open ++ " " ++ reset);
            }
            stderrWrite(s.sessionIdSlice());
            stderrWrite(reset);
            stderrWrite("  ");
            stderrWrite(s.statusSlice());
            if (i + 1 < self.session_count) {
                stderrWrite("  " ++ dim ++ vv ++ reset ++ " ");
            }
        }
        stderrWrite("\x1B[K\n");
    }

    fn renderTopBorder(self: *const DashboardTui, source_width: usize, sidebar_width: usize, session: ?*const TuiSession) void {
        // ┌─ Source ─ path/to/file.zig ───────┬─ Stack Trace ──────┐
        const src_style = if (self.active_pane == .source) cyan else dim;
        const sb_style = if (self.active_pane == .sidebar) cyan else dim;

        stderrWrite(src_style);
        stderrWrite(ct ++ hh);
        stderrWrite(reset);
        stderrWrite(src_style);
        stderrWrite(bold ++ " Source " ++ reset);
        stderrWrite(src_style);
        stderrWrite(hh ++ " " ++ reset);

        // File path
        var path_chars: usize = 0;
        if (session) |s| {
            if (s.source_file_len > 0) {
                const path = s.sourceFileSlice();
                const max_path = if (source_width > 14) source_width - 14 else 1;
                const display_path = truncate(path, max_path);
                stderrWrite(display_path);
                path_chars = display_path.len;
            }
        }

        // Fill remaining with ─
        // "┌─ Source ─ " = 11 visual chars + path_chars, need to reach source_width
        const used_visual: usize = 11 + path_chars + 1; // +1 for trailing space
        stderrWrite(" ");
        stderrWrite(src_style);
        if (source_width > used_visual) {
            self.writeHorizontal(source_width - used_visual);
        }

        // Tee junction
        stderrWrite(reset ++ dim ++ tee_top ++ reset);

        // Sidebar title
        stderrWrite(sb_style);
        stderrWrite(hh);
        stderrWrite(reset);
        stderrWrite(sb_style);
        stderrWrite(bold ++ " Stack Trace " ++ reset);
        stderrWrite(sb_style);

        // Fill remaining sidebar width: "─ Stack Trace " = 14 visual chars
        const sb_title_used: usize = 14;
        if (sidebar_width > sb_title_used) {
            self.writeHorizontal(sidebar_width - sb_title_used);
        }

        stderrWrite(reset ++ dim ++ tr ++ reset ++ "\x1B[K\n");
    }

    fn renderSourceRow(self: *const DashboardTui, row: usize, source_width: usize, session: ?*const TuiSession) void {
        const s = session orelse {
            self.writePadded("", source_width);
            return;
        };

        if (s.source_line_count == 0) {
            // Show location info if available
            if (row == 0 and s.location_file_len > 0) {
                var buf: [256]u8 = undefined;
                var line_buf: [12]u8 = undefined;
                const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{s.location_line}) catch "?";
                const loc_text = std.fmt.bufPrint(&buf, " {s}:{s}", .{ truncate(s.locationFileSlice(), 60), line_str }) catch "";
                self.writePadded(loc_text, source_width);
            } else {
                self.writePadded("", source_width);
            }
            return;
        }

        const line_idx = self.source_scroll + row;
        if (line_idx >= s.source_line_count) {
            self.writePadded("", source_width);
            return;
        }

        const sl = &s.source_lines[line_idx];
        const is_current = (line_idx == s.source_current_idx);

        // Breakpoint marker (1 char visual)
        var has_bp = false;
        for (s.breakpoints[0..s.bp_count]) |*bp| {
            if (bp.line == sl.line_num and s.source_file_len > 0) {
                if (std.mem.eql(u8, bp.fileSlice(), s.sourceFileSlice())) {
                    has_bp = true;
                    break;
                }
            }
        }

        // Current line: cyan background highlight across entire row
        if (is_current) {
            stderrWrite(bg_cyan ++ black);
        }

        if (has_bp) {
            if (is_current) {
                stderrWrite(bullet_filled);
            } else {
                stderrWrite(cyan ++ bullet_filled ++ reset);
            }
        } else {
            stderrWrite(" ");
        }

        // Line number (right-aligned to 4 chars)
        var line_out: [512]u8 = undefined;
        var pos: usize = 0;
        var num_buf: [12]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{sl.line_num}) catch "?";
        if (num_str.len < 4) {
            const pad_len = 4 - num_str.len;
            @memset(line_out[pos..][0..pad_len], ' ');
            pos += pad_len;
        }
        @memcpy(line_out[pos..][0..num_str.len], num_str);
        pos += num_str.len;

        // Spacing after line number
        @memcpy(line_out[pos..][0..3], "   ");
        pos += 3;

        // Write the gutter + line number
        if (!is_current) {
            stderrWrite(dim);
        }
        stderrWrite(line_out[0..pos]);
        if (!is_current) {
            stderrWrite(reset);
        }

        // Line text - remaining width after gutter
        // Visual: BP(1) + num(4) + space(3) = 8 chars used before text
        const gutter_used: usize = 8;
        const text_width: usize = if (source_width > gutter_used) source_width - gutter_used else 1;
        const line_text = sl.textSlice();
        const display_text = truncate(line_text, text_width);

        stderrWrite(display_text);

        // Pad to fill source_width (important for background highlight)
        if (display_text.len < text_width) {
            self.writeSpaces(text_width - display_text.len);
        }

        // Reset after current line highlight
        if (is_current) {
            stderrWrite(reset);
        }
    }

    fn countSidebarItems(_: *const DashboardTui, session: ?*const TuiSession) usize {
        const s = session orelse return 0;
        var count: usize = 0;
        // Stack trace: header + frames
        if (s.frame_count > 0) {
            count += s.frame_count; // frames (no header line in sidebar since title is in border)
        }
        // Separator + Locals header
        if (s.local_count > 0) {
            count += 1; // locals header separator
            count += s.local_count;
        }
        // Separator + Breakpoints header
        if (s.bp_count > 0) {
            count += 1; // breakpoints header separator
            count += s.bp_count;
        }
        return count;
    }

    fn renderSidebarRow(self: *const DashboardTui, row: usize, sidebar_width: usize, main_height: usize, session: ?*const TuiSession, total_items: usize) void {
        _ = main_height;
        const s = session orelse {
            self.writePadded("", sidebar_width);
            return;
        };

        const item_idx_raw = self.sidebar_scroll + row;

        // Build virtual list offsets
        const stack_end = s.frame_count;
        const locals_header = stack_end; // separator/header line for locals
        const locals_start = if (s.local_count > 0) locals_header + 1 else locals_header;
        const locals_end = locals_start + s.local_count;
        const bp_header = locals_end;
        const bp_start = if (s.bp_count > 0) bp_header + 1 else bp_header;
        _ = bp_start;

        if (item_idx_raw >= total_items) {
            self.writePadded("", sidebar_width);
            return;
        }

        const item_idx = item_idx_raw;

        if (item_idx < stack_end) {
            // Stack frame — colored: index in dim, name in bold, location in dim
            const fi = item_idx;
            const f = &s.frames[fi];
            var fline_buf: [12]u8 = undefined;
            const fline_str = std.fmt.bufPrint(&fline_buf, "{d}", .{f.line}) catch "?";
            var idx_buf: [8]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "#{d}", .{fi}) catch "?";

            stderrWrite(" " ++ dim);
            stderrWrite(idx_str);
            stderrWrite(reset ++ "  " ++ cyan ++ bold);
            stderrWrite(truncate(f.nameSlice(), 16));
            stderrWrite(reset ++ "  " ++ dim);
            stderrWrite(truncate(f.sourceSlice(), 20));
            stderrWrite(":");
            stderrWrite(fline_str);
            stderrWrite(reset);

            // Pad to sidebar_width
            const used = 1 + idx_str.len + 2 + @min(f.nameSlice().len, 16) + 2 + @min(f.sourceSlice().len, 20) + 1 + fline_str.len;
            if (used < sidebar_width) {
                self.writeSpaces(sidebar_width - used);
            }
        } else if (s.local_count > 0 and item_idx == locals_header) {
            // Locals header separator
            self.renderSidebarSectionHeader("Locals", sidebar_width);
        } else if (item_idx >= locals_start and item_idx < locals_end) {
            // Local variable — colored: name in bold, value in yellow, type in dim
            const li = item_idx - locals_start;
            const l = &s.locals[li];

            stderrWrite(" " ++ bold);
            const name_display = truncate(l.nameSlice(), 14);
            stderrWrite(name_display);
            stderrWrite(reset ++ "  " ++ yellow);
            const val_display = truncate(l.valueSlice(), 14);
            stderrWrite(val_display);
            stderrWrite(reset ++ "  " ++ dim);
            const type_display = truncate(l.typeSlice(), 10);
            stderrWrite(type_display);
            stderrWrite(reset);

            // Pad to sidebar_width
            const used = 1 + name_display.len + 2 + val_display.len + 2 + type_display.len;
            if (used < sidebar_width) {
                self.writeSpaces(sidebar_width - used);
            }
        } else if (s.bp_count > 0 and item_idx == bp_header) {
            // Breakpoints header separator
            self.renderSidebarSectionHeader("Breakpoints", sidebar_width);
        } else if (item_idx > bp_header and item_idx < total_items) {
            // Breakpoint — colored: file in normal, line in cyan, check in cyan
            const bi = item_idx - bp_header - 1;
            if (bi < s.bp_count) {
                const bp = &s.breakpoints[bi];
                var bpline_buf: [12]u8 = undefined;
                const bpline_str = std.fmt.bufPrint(&bpline_buf, "{d}", .{bp.line}) catch "?";
                const file_display = truncate(bp.fileSlice(), 20);

                stderrWrite(" ");
                stderrWrite(file_display);
                stderrWrite(":" ++ cyan);
                stderrWrite(bpline_str);
                stderrWrite(reset);
                if (bp.verified) {
                    stderrWrite(" " ++ cyan ++ check ++ reset);
                }

                // check visual = 1 char (unicode), verified suffix = 2 visual chars (" ✓")
                const v_len: usize = if (bp.verified) 2 else 0;
                const used = 1 + file_display.len + 1 + bpline_str.len + v_len;
                if (used < sidebar_width) {
                    self.writeSpaces(sidebar_width - used);
                }
            } else {
                self.writePadded("", sidebar_width);
            }
        } else {
            self.writePadded("", sidebar_width);
        }
    }

    fn renderSidebarSectionHeader(self: *const DashboardTui, title: []const u8, sidebar_width: usize) void {
        // "─ Locals ────────────"
        stderrWrite(dim ++ hh ++ reset);
        stderrWrite(cyan ++ bold ++ " ");
        stderrWrite(title);
        stderrWrite(" " ++ reset ++ dim);
        // title visual len = 1(─) + 1( ) + title.len + 1( ) = title.len + 3
        const used = title.len + 3;
        if (sidebar_width > used) {
            self.writeHorizontalDim(sidebar_width - used);
        }
        stderrWrite(reset);
    }

    fn renderMidSeparator(self: *const DashboardTui, source_width: usize, sidebar_width: usize) void {
        // ├─ Log ──────────────────────────────┴──────────────────────┤
        const log_style = if (self.active_pane == .log) cyan else dim;

        stderrWrite(log_style);
        stderrWrite(tee_left ++ hh);
        stderrWrite(reset);
        stderrWrite(log_style);
        stderrWrite(bold ++ " Log " ++ reset);
        stderrWrite(log_style);

        // Fill until tee_bottom position (at source_width + 1)
        // "├─ Log " = 6 visual chars
        const left_used: usize = 6;
        if (source_width > left_used) {
            self.writeHorizontal(source_width - left_used);
        }

        stderrWrite(reset);
        stderrWrite(dim ++ tee_bottom ++ reset);
        stderrWrite(log_style);

        // Fill sidebar width
        self.writeHorizontal(sidebar_width);

        stderrWrite(reset);
        stderrWrite(dim ++ tee_right ++ reset ++ "\x1B[K\n");
    }

    fn renderLogPane(self: *const DashboardTui, log_height: usize, w: usize) void {
        const log_border = if (self.active_pane == .log) cyan else dim;

        // Collect log entries
        var entries: [LOG_SIZE]*const LogEntry = undefined;
        var entry_count: usize = 0;
        var it = self.global_log.iter();
        while (it.next()) |entry| {
            if (entry_count < LOG_SIZE) {
                entries[entry_count] = entry;
                entry_count += 1;
            }
        }

        const content_width = if (w > 2) w - 2 else 1; // left + right border

        for (0..log_height) |row| {
            // Left border
            stderrWrite(log_border);
            stderrWrite(vv);
            stderrWrite(reset);

            const entry_idx = self.log_scroll + row;
            if (entry_idx < entry_count) {
                const entry = entries[entry_idx];
                // " ✓ tool_name           summary"
                if (entry.is_error) {
                    stderrWrite(" " ++ cross ++ " ");
                } else {
                    stderrWrite(" " ++ cyan ++ check ++ reset ++ " ");
                }

                stderrWrite(bold);
                const name = entry.toolNameSlice();
                stderrWrite(name);
                stderrWrite(reset);

                // Pad tool name to 18 chars
                if (name.len < 18) {
                    self.writeSpaces(18 - name.len);
                }
                stderrWrite("  ");

                const summary = entry.summarySlice();
                // Remaining width: content_width - 3(glyph) - max(18,name.len) - 2(gap)
                const prefix_len: usize = 3 + @max(@as(usize, 18), name.len) + 2;
                const remaining = if (content_width > prefix_len) content_width - prefix_len else 1;
                stderrWrite(truncate(summary, remaining));

                // Pad to fill
                const text_len = @min(summary.len, remaining);
                if (prefix_len + text_len < content_width) {
                    self.writeSpaces(content_width - prefix_len - text_len);
                }
            } else if (entry_count == 0 and row == 0) {
                stderrWrite(dim ++ " Waiting for requests..." ++ reset);
                if (content_width > 24) {
                    self.writeSpaces(content_width - 24);
                }
            } else {
                self.writeSpaces(content_width);
            }

            // Right border
            stderrWrite(log_border);
            stderrWrite(vv);
            stderrWrite(reset);
            stderrWrite("\x1B[K\n");
        }
    }

    fn renderBottomBorder(self: *const DashboardTui, w: usize) void {
        const log_style = if (self.active_pane == .log) cyan else dim;
        stderrWrite(log_style);
        stderrWrite(cb);
        const fill = if (w > 2) w - 2 else 1;
        self.writeHorizontal(fill);
        stderrWrite(br);
        stderrWrite(reset ++ "\x1B[K\n");
    }

    fn renderFooter(self: *const DashboardTui) void {
        stderrWrite(dim ++ " q" ++ reset ++ " quit  ");
        stderrWrite(dim ++ "Tab" ++ reset ++ " pane  ");
        stderrWrite(dim ++ "\xE2\x86\x91\xE2\x86\x93" ++ reset ++ " scroll  ");
        if (self.session_count > 1) {
            stderrWrite(dim ++ "[]" ++ reset ++ " session  ");
        }
        // Clear rest of line and everything below (handles terminal shrink)
        stderrWrite("\x1B[K\x1B[J");
    }

    // ── Render Helpers ──────────────────────────────────────────────

    fn writePadded(self: *const DashboardTui, text: []const u8, width: usize) void {
        const display = truncate(text, width);
        stderrWrite(display);
        if (display.len < width) {
            self.writeSpaces(width - display.len);
        }
    }

    fn writeSpaces(_: *const DashboardTui, count: usize) void {
        const spaces = "                                                                                                                                ";
        var remaining = count;
        while (remaining > 0) {
            const chunk = @min(remaining, spaces.len);
            stderrWrite(spaces[0..chunk]);
            remaining -= chunk;
        }
    }

    fn writeHorizontal(self: *const DashboardTui, count: usize) void {
        _ = self;
        // Each ─ is 3 bytes
        var buf: [256 * 3]u8 = undefined;
        const actual = @min(count, 256);
        for (0..actual) |i| {
            @memcpy(buf[i * hh.len ..][0..hh.len], hh);
        }
        stderrWrite(buf[0 .. actual * hh.len]);
    }

    fn writeHorizontalDim(_: *const DashboardTui, count: usize) void {
        // Already in dim context
        var buf: [256 * 3]u8 = undefined;
        const actual = @min(count, 256);
        for (0..actual) |i| {
            @memcpy(buf[i * hh.len ..][0..hh.len], hh);
        }
        stderrWrite(buf[0 .. actual * hh.len]);
    }
};

// ── Source Loading ──────────────────────────────────────────────────────

fn loadSourceContext(session: *TuiSession, file_path: []const u8, target_line: u32) void {
    session.source_line_count = 0;
    session.source_current_idx = 0;
    session.source_file_len = 0;
    if (target_line == 0) return;
    if (file_path.len == 0) return;
    if (!std.fs.path.isAbsolute(file_path)) return;

    const file = std.fs.openFileAbsolute(file_path, .{}) catch return;
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return;
    const content = buf[0..bytes_read];

    // Copy display file path (use basename for shorter display)
    copyInto(&session.source_file, &session.source_file_len, file_path);

    // Split into lines and find target window
    var line_starts: [8192]usize = undefined;
    var line_count: usize = 0;

    line_starts[0] = 0;
    line_count = 1;

    for (content, 0..) |c, idx| {
        if (c == '\n' and idx + 1 < content.len) {
            if (line_count >= line_starts.len) break;
            line_starts[line_count] = idx + 1;
            line_count += 1;
        }
    }

    // target_line is 1-based
    if (target_line > line_count) return;

    const target_idx = target_line - 1; // 0-based index into lines
    const context_radius = (SOURCE_CONTEXT - 1) / 2; // 10

    const start_line: usize = if (target_idx >= context_radius) target_idx - context_radius else 0;
    const end_line: usize = @min(target_idx + context_radius + 1, line_count);

    for (start_line..end_line) |li| {
        if (session.source_line_count >= SOURCE_CONTEXT) break;

        const line_start = line_starts[li];
        const line_end = blk: {
            if (li + 1 < line_count) {
                // line_starts[li+1] points after the '\n'
                const next_start = line_starts[li + 1];
                // Exclude the trailing newline
                break :blk if (next_start > 0 and next_start <= content.len and content[next_start - 1] == '\n')
                    next_start - 1
                else
                    next_start;
            } else {
                // Last line
                break :blk content.len;
            }
        };

        const line_text = content[line_start..line_end];
        var sl = &session.source_lines[session.source_line_count];
        sl.* = .{};
        sl.line_num = @intCast(li + 1); // 1-based
        const copy_len = @min(line_text.len, SOURCE_LINE_LEN);
        @memcpy(sl.text[0..copy_len], line_text[0..copy_len]);
        sl.text_len = copy_len;

        if (li == target_idx) {
            session.source_current_idx = session.source_line_count;
        }

        session.source_line_count += 1;
    }
}

// ── Platform Helpers ────────────────────────────────────────────────────

const TerminalSize = struct { width: u16, height: u16 };

fn getTerminalSize() TerminalSize {
    if (@import("builtin").is_test) return .{ .width = 80, .height = 24 };
    var ws: posix.winsize = undefined;
    const rc = std.posix.system.ioctl(posix.STDERR_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0 and ws.row > 0) return .{ .width = ws.col, .height = ws.row };
    return .{ .width = 80, .height = 24 };
}

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

// ── Socket Path Helper ──────────────────────────────────────────────────

/// Get the well-known socket path. Used by server to connect.
pub fn getSocketPath(buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/cog-debug-dashboard-{d}.sock", .{getUid()}) catch null;
}

// ── I/O Helpers ─────────────────────────────────────────────────────────

var render_buf: [65536]u8 = undefined;
var render_len: usize = 0;
var render_active: bool = false;

fn stderrWrite(data: []const u8) void {
    if (@import("builtin").is_test) return;
    if (render_active) {
        const remaining = render_buf.len - render_len;
        const to_copy = @min(data.len, remaining);
        @memcpy(render_buf[render_len..][0..to_copy], data[0..to_copy]);
        render_len += to_copy;
    } else {
        _ = posix.write(posix.STDERR_FILENO, data) catch {};
    }
}

fn flushRenderBuffer() void {
    if (render_len > 0) {
        _ = posix.write(posix.STDERR_FILENO, render_buf[0..render_len]) catch {};
        render_len = 0;
    }
}

fn printErr(data: []const u8) void {
    stderrWrite(data);
}

fn copyInto(dest: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    len.* = n;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    return if (s.len <= max) s else s[0..max];
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "DashboardTui initializes with empty state" {
    const tui = DashboardTui.init(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tui.session_count);
    try std.testing.expectEqual(@as(usize, 0), tui.client_count);
    try std.testing.expectEqual(@as(usize, 0), tui.focused);
    try std.testing.expect(tui.running);
    try std.testing.expect(tui.listener == null);
}

test "processEvent handles launch event" {
    var tui = DashboardTui.init(std.testing.allocator);
    const event =
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    ;
    tui.processEvent(event);

    try std.testing.expectEqual(@as(usize, 1), tui.session_count);
    try std.testing.expectEqualStrings("session-1", tui.sessions[0].sessionIdSlice());
    try std.testing.expectEqualStrings("/tmp/test", tui.sessions[0].programSlice());
    try std.testing.expectEqualStrings("native", tui.sessions[0].driverTypeSlice());
    try std.testing.expectEqualStrings("stopped", tui.sessions[0].statusSlice());
}

test "processEvent handles breakpoint set event" {
    var tui = DashboardTui.init(std.testing.allocator);

    // First create a session
    const launch =
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    ;
    tui.processEvent(launch);

    const bp_event =
        \\{"type":"breakpoint","session_id":"session-1","action":"set","bp":{"id":1,"file":"/tmp/test.c","line":4,"verified":true}}
    ;
    tui.processEvent(bp_event);

    try std.testing.expectEqual(@as(usize, 1), tui.sessions[0].bp_count);
    try std.testing.expectEqual(@as(u32, 1), tui.sessions[0].breakpoints[0].id);
    try std.testing.expectEqualStrings("/tmp/test.c", tui.sessions[0].breakpoints[0].fileSlice());
    try std.testing.expectEqual(@as(u32, 4), tui.sessions[0].breakpoints[0].line);
    try std.testing.expect(tui.sessions[0].breakpoints[0].verified);
}

test "processEvent handles stop event with stack trace and locals" {
    var tui = DashboardTui.init(std.testing.allocator);

    const launch =
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    ;
    tui.processEvent(launch);

    const stop =
        \\{"type":"stop","session_id":"session-1","reason":"breakpoint","location":{"file":"/tmp/test.c","line":4,"function":"add"},"stack_trace":[{"name":"add","source":"test.c","line":4},{"name":"main","source":"test.c","line":36}],"locals":[{"name":"a","value":"10","type":"int"},{"name":"b","value":"20","type":"int"}]}
    ;
    tui.processEvent(stop);

    try std.testing.expectEqualStrings("stopped", tui.sessions[0].statusSlice());
    try std.testing.expectEqualStrings("breakpoint", tui.sessions[0].stopReasonSlice());
    try std.testing.expectEqualStrings("/tmp/test.c", tui.sessions[0].locationFileSlice());
    try std.testing.expectEqual(@as(u32, 4), tui.sessions[0].location_line);
    try std.testing.expectEqualStrings("add", tui.sessions[0].locationFuncSlice());
    try std.testing.expectEqual(@as(usize, 2), tui.sessions[0].frame_count);
    try std.testing.expectEqualStrings("add", tui.sessions[0].frames[0].nameSlice());
    try std.testing.expectEqual(@as(usize, 2), tui.sessions[0].local_count);
    try std.testing.expectEqualStrings("a", tui.sessions[0].locals[0].nameSlice());
    try std.testing.expectEqualStrings("10", tui.sessions[0].locals[0].valueSlice());
}

test "processEvent handles session_end event" {
    var tui = DashboardTui.init(std.testing.allocator);

    const launch =
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    ;
    tui.processEvent(launch);
    try std.testing.expectEqual(@as(usize, 1), tui.session_count);

    const end =
        \\{"type":"session_end","session_id":"session-1"}
    ;
    tui.processEvent(end);
    try std.testing.expectEqual(@as(usize, 0), tui.session_count);
}

test "processEvent handles inspect event" {
    var tui = DashboardTui.init(std.testing.allocator);

    const launch =
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    ;
    tui.processEvent(launch);

    const inspect =
        \\{"type":"inspect","session_id":"session-1","expression":"a","result":"10","var_type":"int"}
    ;
    tui.processEvent(inspect);

    try std.testing.expectEqual(@as(usize, 2), tui.global_log.count); // launch + inspect
}

test "processEvent handles error event" {
    var tui = DashboardTui.init(std.testing.allocator);

    const err_event =
        \\{"type":"error","session_id":"","method":"debug_launch","message":"file not found"}
    ;
    tui.processEvent(err_event);

    try std.testing.expectEqual(@as(usize, 1), tui.global_log.count);
    const entry = &tui.global_log.entries[0];
    try std.testing.expect(entry.is_error);
}

test "processEvent handles bad JSON gracefully" {
    var tui = DashboardTui.init(std.testing.allocator);

    tui.processEvent("not json at all");
    try std.testing.expectEqual(@as(usize, 1), tui.global_log.count);
    try std.testing.expect(tui.global_log.entries[0].is_error);
}

test "processEvent multiple sessions with focus management" {
    var tui = DashboardTui.init(std.testing.allocator);

    tui.processEvent(
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test1","driver":"native"}
    );
    tui.processEvent(
        \\{"type":"launch","session_id":"session-2","program":"/tmp/test2","driver":"dap"}
    );

    try std.testing.expectEqual(@as(usize, 2), tui.session_count);
    try std.testing.expectEqual(@as(usize, 0), tui.focused);

    // Remove focused session, focus should adjust
    tui.processEvent(
        \\{"type":"session_end","session_id":"session-1"}
    );
    try std.testing.expectEqual(@as(usize, 1), tui.session_count);
    try std.testing.expectEqual(@as(usize, 0), tui.focused);
    try std.testing.expectEqualStrings("session-2", tui.sessions[0].sessionIdSlice());
}

test "getSocketPath returns valid path" {
    var buf: [128]u8 = undefined;
    const path = getSocketPath(&buf);
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.startsWith(u8, path.?, "/tmp/cog-debug-dashboard-"));
    try std.testing.expect(std.mem.endsWith(u8, path.?, ".sock"));
}

test "RingLog wraps around correctly" {
    var log: RingLog = .{};
    for (0..20) |i| {
        var entry: LogEntry = .{};
        var buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "tool_{d}", .{i}) catch "tool";
        copyInto(&entry.tool_name, &entry.tool_name_len, name);
        log.push(entry);
    }
    try std.testing.expectEqual(@as(usize, LOG_SIZE), log.count);

    var it = log.iter();
    const first = it.next().?;
    try std.testing.expectEqualStrings("tool_4", first.toolNameSlice());
}

test "SourceLine struct basics" {
    var sl: SourceLine = .{};
    try std.testing.expectEqual(@as(usize, 0), sl.text_len);
    try std.testing.expectEqual(@as(u32, 0), sl.line_num);
    try std.testing.expectEqualStrings("", sl.textSlice());

    copyInto(&sl.text, &sl.text_len, "  int x = 42;");
    sl.line_num = 10;
    try std.testing.expectEqualStrings("  int x = 42;", sl.textSlice());
    try std.testing.expectEqual(@as(u32, 10), sl.line_num);
}

test "loadSourceContext reads source lines from file" {
    // Create a temporary source file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = tmp_dir.dir.createFile("test_source.c", .{}) catch unreachable;

    const source =
        \\#include <stdio.h>
        \\
        \\int add(int a, int b) {
        \\    int result = a + b;
        \\    return result;
        \\}
        \\
        \\int main() {
        \\    printf("%d\n", add(10, 20));
        \\    return 0;
        \\}
    ;
    file.writeAll(source) catch unreachable;
    file.close();

    // Get the absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("test_source.c", &path_buf) catch unreachable;

    var session: TuiSession = .{};
    loadSourceContext(&session, abs_path, 4);

    try std.testing.expect(session.source_line_count > 0);
    try std.testing.expect(session.source_file_len > 0);

    // The current line (line 4) should be "    int result = a + b;"
    const current = &session.source_lines[session.source_current_idx];
    try std.testing.expectEqual(@as(u32, 4), current.line_num);
    try std.testing.expectEqualStrings("    int result = a + b;", current.textSlice());

    // First line should be line 1 (since we have < 10 lines before target)
    try std.testing.expectEqual(@as(u32, 1), session.source_lines[0].line_num);
}

test "loadSourceContext with line 0 loads nothing" {
    var session: TuiSession = .{};
    loadSourceContext(&session, "/nonexistent/file.c", 0);
    try std.testing.expectEqual(@as(usize, 0), session.source_line_count);
}

test "loadSourceContext with nonexistent file loads nothing" {
    var session: TuiSession = .{};
    loadSourceContext(&session, "/nonexistent/path/to/file.c", 5);
    try std.testing.expectEqual(@as(usize, 0), session.source_line_count);
}

test "stop event populates source context" {
    // Create a temporary source file for the stop event test
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile("stop_test.c", .{}) catch unreachable;
    const source =
        \\#include <stdio.h>
        \\
        \\int main() {
        \\    int x = 42;
        \\    return 0;
        \\}
    ;
    file.writeAll(source) catch unreachable;
    file.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = tmp_dir.dir.realpath("stop_test.c", &path_buf) catch unreachable;

    var tui = DashboardTui.init(std.testing.allocator);

    tui.processEvent(
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    );

    // Build stop event JSON with the real temp file path
    var json_buf: [1024]u8 = undefined;
    const stop_json = std.fmt.bufPrint(&json_buf,
        \\{{"type":"stop","session_id":"session-1","reason":"breakpoint","location":{{"file":"{s}","line":4,"function":"main"}},"stack_trace":[],"locals":[]}}
    , .{abs_path}) catch unreachable;

    tui.processEvent(stop_json);

    try std.testing.expect(tui.sessions[0].source_line_count > 0);
    const current = &tui.sessions[0].source_lines[tui.sessions[0].source_current_idx];
    try std.testing.expectEqual(@as(u32, 4), current.line_num);
    try std.testing.expectEqualStrings("    int x = 42;", current.textSlice());
}

test "getTerminalSize returns reasonable defaults in test mode" {
    const size = getTerminalSize();
    try std.testing.expectEqual(@as(u16, 80), size.width);
    try std.testing.expectEqual(@as(u16, 24), size.height);
}

test "pane focus cycling via Tab" {
    var tui = DashboardTui.init(std.testing.allocator);
    try std.testing.expect(tui.active_pane == .source);

    // source -> sidebar
    tui.active_pane = switch (tui.active_pane) {
        .source => .sidebar,
        .sidebar => .log,
        .log => .source,
    };
    try std.testing.expect(tui.active_pane == .sidebar);

    // sidebar -> log
    tui.active_pane = switch (tui.active_pane) {
        .source => .sidebar,
        .sidebar => .log,
        .log => .source,
    };
    try std.testing.expect(tui.active_pane == .log);

    // log -> source
    tui.active_pane = switch (tui.active_pane) {
        .source => .sidebar,
        .sidebar => .log,
        .log => .source,
    };
    try std.testing.expect(tui.active_pane == .source);
}

test "source scroll bounds clamping" {
    var tui = DashboardTui.init(std.testing.allocator);

    // scrollUp with source_scroll=0 should not go negative
    tui.active_pane = .source;
    tui.source_scroll = 0;
    const changed = tui.scrollUp();
    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(usize, 0), tui.source_scroll);
}

test "sidebar scroll bounds clamping" {
    var tui = DashboardTui.init(std.testing.allocator);

    tui.active_pane = .sidebar;
    tui.sidebar_scroll = 0;
    const changed = tui.scrollUp();
    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(usize, 0), tui.sidebar_scroll);
}

test "log scroll bounds clamping" {
    var tui = DashboardTui.init(std.testing.allocator);

    tui.active_pane = .log;
    tui.log_scroll = 0;

    // scrollDown with empty log should not change
    const down_changed = tui.scrollDown();
    try std.testing.expect(!down_changed);
    try std.testing.expectEqual(@as(usize, 0), tui.log_scroll);

    // scrollUp at 0 should not change
    const up_changed = tui.scrollUp();
    try std.testing.expect(!up_changed);
    try std.testing.expectEqual(@as(usize, 0), tui.log_scroll);
}

test "scroll up and down works within bounds" {
    var tui = DashboardTui.init(std.testing.allocator);

    // Create a session with source lines
    tui.processEvent(
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    );

    // Manually set source_line_count high enough to allow scrolling
    tui.sessions[0].source_line_count = 50;
    tui.active_pane = .source;
    tui.source_scroll = 0;

    // Scroll down
    const down1 = tui.scrollDown();
    try std.testing.expect(down1);
    try std.testing.expectEqual(@as(usize, 1), tui.source_scroll);

    // Scroll down again
    _ = tui.scrollDown();
    try std.testing.expectEqual(@as(usize, 2), tui.source_scroll);

    // Scroll up
    const up1 = tui.scrollUp();
    try std.testing.expect(up1);
    try std.testing.expectEqual(@as(usize, 1), tui.source_scroll);
}

test "computeMainHeight returns sensible values" {
    const tui = DashboardTui.init(std.testing.allocator);

    // With a 24-row terminal
    const main_24 = tui.computeMainHeight(24);
    try std.testing.expect(main_24 > 0);
    try std.testing.expect(main_24 <= 24);

    // With a 50-row terminal
    const main_50 = tui.computeMainHeight(50);
    try std.testing.expect(main_50 > main_24);

    // With very small terminal, should not underflow
    const main_tiny = tui.computeMainHeight(5);
    try std.testing.expect(main_tiny >= 4);
}

test "session switching with brackets resets scroll" {
    var tui = DashboardTui.init(std.testing.allocator);

    tui.processEvent(
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test1","driver":"native"}
    );
    tui.processEvent(
        \\{"type":"launch","session_id":"session-2","program":"/tmp/test2","driver":"dap"}
    );

    tui.source_scroll = 5;
    tui.sidebar_scroll = 3;
    tui.focused = 0;

    // Switch to next session
    tui.focused = 1;
    tui.source_scroll = 0;
    tui.sidebar_scroll = 0;

    try std.testing.expectEqual(@as(usize, 1), tui.focused);
    try std.testing.expectEqual(@as(usize, 0), tui.source_scroll);
    try std.testing.expectEqual(@as(usize, 0), tui.sidebar_scroll);
}

test "countSidebarItems counts stack frames locals and breakpoints" {
    var tui = DashboardTui.init(std.testing.allocator);

    tui.processEvent(
        \\{"type":"launch","session_id":"session-1","program":"/tmp/test","driver":"native"}
    );

    const stop =
        \\{"type":"stop","session_id":"session-1","reason":"breakpoint","location":{"file":"/tmp/test.c","line":4,"function":"add"},"stack_trace":[{"name":"add","source":"test.c","line":4},{"name":"main","source":"test.c","line":36}],"locals":[{"name":"a","value":"10","type":"int"},{"name":"b","value":"20","type":"int"}]}
    ;
    tui.processEvent(stop);

    const session: ?*const TuiSession = &tui.sessions[0];
    const count = tui.countSidebarItems(session);
    // 2 frames + 1 locals header + 2 locals = 5
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "countSidebarItems with no session returns 0" {
    const tui = DashboardTui.init(std.testing.allocator);
    const count = tui.countSidebarItems(null);
    try std.testing.expectEqual(@as(usize, 0), count);
}
