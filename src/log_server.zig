const std = @import("std");
const json = std.json;
const posix = std.posix;
const debug_log = @import("debug_log.zig");

const Allocator = std.mem.Allocator;

// ── Log Format Detection ────────────────────────────────────────────────

pub const LogFormat = enum {
    json_lines,
    logfmt,
    timestamped,
    plaintext,

    pub fn label(self: LogFormat) []const u8 {
        return switch (self) {
            .json_lines => "json_lines",
            .logfmt => "logfmt",
            .timestamped => "timestamped",
            .plaintext => "plaintext",
        };
    }
};

pub const LogLevel = enum(u3) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn fromString(s: []const u8) ?LogLevel {
        if (s.len == 0) return null;
        if (asciiEqlIgnoreCase(s, "trace")) return .trace;
        if (asciiEqlIgnoreCase(s, "debug")) return .debug;
        if (asciiEqlIgnoreCase(s, "info")) return .info;
        if (asciiEqlIgnoreCase(s, "information")) return .info;
        if (asciiEqlIgnoreCase(s, "informational")) return .info;
        if (asciiEqlIgnoreCase(s, "warn")) return .warn;
        if (asciiEqlIgnoreCase(s, "warning")) return .warn;
        if (asciiEqlIgnoreCase(s, "error")) return .err;
        if (asciiEqlIgnoreCase(s, "err")) return .err;
        if (asciiEqlIgnoreCase(s, "fatal")) return .fatal;
        if (asciiEqlIgnoreCase(s, "critical")) return .fatal;
        if (asciiEqlIgnoreCase(s, "crit")) return .fatal;
        if (asciiEqlIgnoreCase(s, "panic")) return .fatal;
        if (asciiEqlIgnoreCase(s, "emerg")) return .fatal;
        if (asciiEqlIgnoreCase(s, "emergency")) return .fatal;
        if (asciiEqlIgnoreCase(s, "alert")) return .fatal;
        // Single-char levels (MongoDB, klog, etc.)
        if (s.len == 1) {
            return switch (s[0]) {
                'D', 'd' => .debug,
                'I', 'i' => .info,
                'W', 'w' => .warn,
                'E', 'e' => .err,
                'F', 'f' => .fatal,
                'N', 'n' => .info, // notice
                'T', 't' => .trace,
                '0', '1', '2' => .fatal, // emerg, alert, crit
                '3' => .err,
                '4' => .warn,
                '5', '6' => .info, // notice, info
                '7' => .debug,
                else => null,
            };
        }
        return null;
    }

    pub fn meetsMinimum(self: LogLevel, min: LogLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(min);
    }
};

// ── Log Session ─────────────────────────────────────────────────────────

pub const LogSession = struct {
    id: []const u8,
    path: []const u8,
    file: std.fs.File,
    read_offset: u64,
    detected_format: LogFormat,
    line_count: u64,
    created_at: i64,

    pub fn deinit(self: *LogSession, allocator: Allocator) void {
        self.file.close();
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

// ── Output helper ───────────────────────────────────────────────────────

const Output = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    fn init(allocator: Allocator) Output {
        return .{ .buf = .empty, .allocator = allocator };
    }

    fn print(self: *Output, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.buf.writer(self.allocator), fmt, args) catch {};
    }

    fn append(self: *Output, str: []const u8) void {
        self.buf.appendSlice(self.allocator, str) catch {};
    }

    fn appendByte(self: *Output, byte: u8) void {
        self.buf.append(self.allocator, byte) catch {};
    }

    fn toOwnedSlice(self: *Output) ![]const u8 {
        return try self.buf.toOwnedSlice(self.allocator);
    }

    fn deinit(self: *Output) void {
        self.buf.deinit(self.allocator);
    }
};

// ── Log Server ──────────────────────────────────────────────────────────

pub const LogServer = struct {
    allocator: Allocator,
    sessions: std.StringHashMapUnmanaged(LogSession),
    next_id: u32,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) LogServer {
        debug_log.log("LogServer.init", .{});
        return .{
            .allocator = allocator,
            .sessions = .empty,
            .next_id = 1,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *LogServer) void {
        debug_log.log("LogServer.deinit: closing {d} sessions", .{self.sessions.count()});
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.sessions.deinit(self.allocator);
    }

    // ── Tool Dispatch ───────────────────────────────────────────────────

    pub fn callTool(self: *LogServer, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const suffix = if (std.mem.startsWith(u8, tool_name, "log_"))
            tool_name["log_".len..]
        else
            tool_name;

        debug_log.log("LogServer.callTool: dispatching {s} (suffix={s})", .{ tool_name, suffix });

        if (std.mem.eql(u8, suffix, "watch")) return self.toolWatch(arguments);
        if (std.mem.eql(u8, suffix, "tail")) return self.toolTail(arguments);
        if (std.mem.eql(u8, suffix, "search")) return self.toolSearch(arguments);
        if (std.mem.eql(u8, suffix, "errors")) return self.toolErrors(arguments);
        if (std.mem.eql(u8, suffix, "overview")) return self.toolOverview(arguments);
        if (std.mem.eql(u8, suffix, "sessions")) return self.toolSessions(arguments);
        if (std.mem.eql(u8, suffix, "stop")) return self.toolStop(arguments);

        return try std.fmt.allocPrint(self.allocator, "Error: unknown log tool '{s}'", .{tool_name});
    }

    // ── log_watch ───────────────────────────────────────────────────────

    fn toolWatch(self: *LogServer, arguments: ?json.Value) ![]const u8 {
        const args = arguments orelse return try self.allocator.dupe(u8, "Error: missing arguments (required: path)");

        const path = getStr(args, "path") orelse
            return try self.allocator.dupe(u8, "Error: 'path' is required");
        const from_end = getBool(args, "from_end") orelse true;
        const tail_lines: usize = getInt(args, "tail_lines") orelse 50;

        debug_log.log("log_watch: path={s} from_end={} tail_lines={d}", .{ path, from_end, tail_lines });

        // Open the file
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |e| {
            // Try relative path
            const cwd_file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
                return try std.fmt.allocPrint(self.allocator, "Error: cannot open file '{s}': {s}", .{ path, @errorName(e) });
            };
            return self.createSession(path, cwd_file, from_end, tail_lines);
        };
        return self.createSession(path, file, from_end, tail_lines);
    }

    fn createSession(self: *LogServer, path: []const u8, file: std.fs.File, from_end: bool, tail_lines: usize) ![]const u8 {
        const stat = file.stat() catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: cannot stat file: {s}", .{@errorName(e)});
        };
        const file_size = stat.size;

        // Generate session ID
        const id = try std.fmt.allocPrint(self.allocator, "log_{d}", .{self.next_id});
        self.next_id += 1;

        // Read sample for format detection + optional tail
        const sample_buf = readFileTail(self.allocator, file, file_size) catch |e| {
            self.allocator.free(id);
            return try std.fmt.allocPrint(self.allocator, "Error: cannot read file: {s}", .{@errorName(e)});
        };
        defer self.allocator.free(sample_buf);

        const format = detectFormat(self.allocator, sample_buf);
        debug_log.log("log_watch: detected format={s} for {s}", .{ format.label(), path });

        // Get the initial tail lines if from_end
        var initial_lines: []const u8 = "";
        var initial_count: usize = 0;
        var offset: u64 = 0;

        if (from_end) {
            offset = file_size;
            if (tail_lines > 0 and sample_buf.len > 0) {
                const tail_result = extractLastNLines(self.allocator, sample_buf, tail_lines) catch
                    TailResult{ .text = "", .count = 0 };
                initial_lines = tail_result.text;
                initial_count = tail_result.count;
            }
        }

        // Store path as owned copy
        const owned_path = try self.allocator.dupe(u8, path);

        const session = LogSession{
            .id = id,
            .path = owned_path,
            .file = file,
            .read_offset = offset,
            .detected_format = format,
            .line_count = countLines(sample_buf),
            .created_at = std.time.timestamp(),
        };

        const id_key = try self.allocator.dupe(u8, id);
        try self.sessions.put(self.allocator, id_key, session);

        debug_log.log("log_watch: created session {s} offset={d}", .{ id, offset });

        // Build response
        var out = Output.init(self.allocator);
        errdefer out.deinit();

        out.print("Session started: {s}\n", .{id});
        out.print("File: {s}\n", .{path});
        out.print("Size: {d} bytes\n", .{file_size});
        out.print("Format: {s}\n", .{format.label()});
        if (initial_count > 0 and initial_lines.len > 0) {
            out.print("Initial tail ({d} lines):\n---\n{s}\n", .{ initial_count, initial_lines });
            self.allocator.free(initial_lines);
        }

        return out.toOwnedSlice();
    }

    // ── log_tail ────────────────────────────────────────────────────────

    fn toolTail(self: *LogServer, arguments: ?json.Value) ![]const u8 {
        const args = arguments orelse return try self.allocator.dupe(u8, "Error: missing arguments (required: session)");

        const session_id = getStr(args, "session") orelse
            return try self.allocator.dupe(u8, "Error: 'session' is required");
        const max_lines: usize = getInt(args, "max_lines") orelse 200;
        const level_str = getStr(args, "level");
        const pattern = getStr(args, "pattern");

        debug_log.log("log_tail: session={s} max_lines={d}", .{ session_id, max_lines });

        const session = self.sessions.getPtr(session_id) orelse
            return try std.fmt.allocPrint(self.allocator, "Error: session '{s}' not found", .{session_id});

        const min_level: ?LogLevel = if (level_str) |ls| LogLevel.fromString(ls) else null;

        // Get current file size
        const stat = session.file.stat() catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: cannot stat file: {s}", .{@errorName(e)});
        };
        const current_size = stat.size;

        if (current_size <= session.read_offset) {
            if (current_size < session.read_offset) {
                debug_log.log("log_tail: file truncated, resetting offset from {d} to 0", .{session.read_offset});
                session.read_offset = 0;
            }
            return try self.allocator.dupe(u8, "No new lines.");
        }

        const bytes_available = current_size - session.read_offset;
        const read_size: usize = @intCast(@min(bytes_available, 1024 * 1024));

        const data = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(data);

        session.file.seekTo(session.read_offset) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: seek failed: {s}", .{@errorName(e)});
        };
        const bytes_read = session.file.readAll(data) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: read failed: {s}", .{@errorName(e)});
        };

        if (bytes_read == 0) {
            return try self.allocator.dupe(u8, "No new lines.");
        }

        // Advance offset to the end of the last complete line
        const actual_data = data[0..bytes_read];
        var last_newline: usize = bytes_read;
        while (last_newline > 0 and actual_data[last_newline - 1] != '\n') {
            last_newline -= 1;
        }

        if (last_newline == 0) {
            return try self.allocator.dupe(u8, "No complete new lines yet.");
        }

        session.read_offset += last_newline;
        const complete_data = actual_data[0..last_newline];

        const result = try filterLines(self.allocator, complete_data, min_level, pattern, max_lines, session.detected_format);
        defer self.allocator.free(result.lines);

        var out = Output.init(self.allocator);
        errdefer out.deinit();

        if (result.total_lines == 0) {
            out.append("No new lines.");
        } else if (result.filtered_count == result.total_lines) {
            out.print("{d} new lines:\n---\n{s}", .{ result.total_lines, result.lines });
        } else {
            out.print("{d} matching lines ({d} total, {d} filtered out):\n---\n{s}", .{
                result.filtered_count,
                result.total_lines,
                result.total_lines - result.filtered_count,
                result.lines,
            });
        }

        session.line_count += result.total_lines;
        debug_log.log("log_tail: {d} lines read, offset now {d}", .{ result.total_lines, session.read_offset });

        return out.toOwnedSlice();
    }

    // ── log_search ──────────────────────────────────────────────────────

    fn toolSearch(self: *LogServer, arguments: ?json.Value) ![]const u8 {
        const args = arguments orelse return try self.allocator.dupe(u8, "Error: missing arguments (required: session, pattern)");

        const session_id = getStr(args, "session") orelse
            return try self.allocator.dupe(u8, "Error: 'session' is required");
        const pattern = getStr(args, "pattern") orelse
            return try self.allocator.dupe(u8, "Error: 'pattern' is required");
        const level_str = getStr(args, "level");
        const max_results: usize = getInt(args, "max_results") orelse 50;
        const context_lines: usize = getInt(args, "context_lines") orelse 0;

        debug_log.log("log_search: session={s} pattern={s} max_results={d}", .{ session_id, pattern, max_results });

        const session = self.sessions.getPtr(session_id) orelse
            return try std.fmt.allocPrint(self.allocator, "Error: session '{s}' not found", .{session_id});

        const min_level: ?LogLevel = if (level_str) |ls| LogLevel.fromString(ls) else null;

        // Read entire file for search (does NOT advance tail cursor)
        const stat = session.file.stat() catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: cannot stat file: {s}", .{@errorName(e)});
        };

        const read_size: usize = @intCast(@min(stat.size, 10 * 1024 * 1024));
        if (read_size == 0) {
            return try self.allocator.dupe(u8, "File is empty.");
        }

        const file_data = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(file_data);

        session.file.seekTo(0) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: seek failed: {s}", .{@errorName(e)});
        };
        const bytes_read = session.file.readAll(file_data) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: read failed: {s}", .{@errorName(e)});
        };

        if (bytes_read == 0) {
            return try self.allocator.dupe(u8, "File is empty.");
        }

        return try searchLines(self.allocator, file_data[0..bytes_read], pattern, min_level, max_results, context_lines, session.detected_format);
    }

    // ── log_errors ──────────────────────────────────────────────────────

    fn toolErrors(self: *LogServer, arguments: ?json.Value) ![]const u8 {
        const args = arguments orelse return try self.allocator.dupe(u8, "Error: missing arguments (required: session)");

        const session_id = getStr(args, "session") orelse
            return try self.allocator.dupe(u8, "Error: 'session' is required");
        const max_errors: usize = getInt(args, "max_errors") orelse 20;

        debug_log.log("log_errors: session={s} max_errors={d}", .{ session_id, max_errors });

        const session = self.sessions.getPtr(session_id) orelse
            return try std.fmt.allocPrint(self.allocator, "Error: session '{s}' not found", .{session_id});

        const stat = session.file.stat() catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: cannot stat file: {s}", .{@errorName(e)});
        };
        const read_size: usize = @intCast(@min(stat.size, 10 * 1024 * 1024));
        if (read_size == 0) {
            return try self.allocator.dupe(u8, "No errors found (file is empty).");
        }

        const file_data = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(file_data);

        session.file.seekTo(0) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: seek failed: {s}", .{@errorName(e)});
        };
        const bytes_read = session.file.readAll(file_data) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: read failed: {s}", .{@errorName(e)});
        };

        return try extractErrors(self.allocator, file_data[0..bytes_read], max_errors, session.detected_format);
    }

    // ── log_overview ────────────────────────────────────────────────────

    fn toolOverview(self: *LogServer, arguments: ?json.Value) ![]const u8 {
        const args = arguments orelse return try self.allocator.dupe(u8, "Error: missing arguments (required: session)");

        const session_id = getStr(args, "session") orelse
            return try self.allocator.dupe(u8, "Error: 'session' is required");

        debug_log.log("log_overview: session={s}", .{session_id});

        const session = self.sessions.getPtr(session_id) orelse
            return try std.fmt.allocPrint(self.allocator, "Error: session '{s}' not found", .{session_id});

        const stat = session.file.stat() catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: cannot stat file: {s}", .{@errorName(e)});
        };
        const file_size = stat.size;

        const read_size: usize = @intCast(@min(file_size, 10 * 1024 * 1024));
        const file_data = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(file_data);

        session.file.seekTo(0) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: seek failed: {s}", .{@errorName(e)});
        };
        const bytes_read = session.file.readAll(file_data) catch |e| {
            return try std.fmt.allocPrint(self.allocator, "Error: read failed: {s}", .{@errorName(e)});
        };

        const data = file_data[0..bytes_read];
        const total_lines = countLines(data);

        // Level distribution
        var level_counts = [_]usize{0} ** 6;
        var line_iter = std.mem.splitSequence(u8, data, "\n");
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            if (extractLevel(line, session.detected_format)) |lvl| {
                level_counts[@intFromEnum(lvl)] += 1;
            }
        }

        // Head and tail samples
        const head = extractFirstNLines(self.allocator, data, 5) catch "";
        defer if (head.len > 0) self.allocator.free(head);
        const tail_result = extractLastNLines(self.allocator, data, 5) catch TailResult{ .text = "", .count = 0 };
        defer if (tail_result.text.len > 0) self.allocator.free(tail_result.text);

        var out = Output.init(self.allocator);
        errdefer out.deinit();

        out.print("File: {s}\n", .{session.path});
        out.print("Size: {d} bytes\n", .{file_size});
        out.print("Lines: {d}\n", .{total_lines});
        out.print("Format: {s}\n", .{session.detected_format.label()});
        out.print("Cursor offset: {d}\n", .{session.read_offset});

        out.append("\nLevel distribution:\n");
        const level_names = [_][]const u8{ "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL" };
        for (level_counts, 0..) |count, i| {
            if (count > 0) {
                out.print("  {s}: {d}\n", .{ level_names[i], count });
            }
        }

        if (head.len > 0) {
            out.print("\nFirst 5 lines:\n---\n{s}\n", .{head});
        }
        if (tail_result.text.len > 0) {
            out.print("\nLast 5 lines:\n---\n{s}\n", .{tail_result.text});
        }

        return out.toOwnedSlice();
    }

    // ── log_sessions ────────────────────────────────────────────────────

    fn toolSessions(self: *LogServer, _: ?json.Value) ![]const u8 {
        debug_log.log("log_sessions: listing {d} sessions", .{self.sessions.count()});

        if (self.sessions.count() == 0) {
            return try self.allocator.dupe(u8, "No active log sessions.");
        }

        var out = Output.init(self.allocator);
        errdefer out.deinit();

        out.print("Active log sessions ({d}):\n\n", .{self.sessions.count()});

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const s = entry.value_ptr;
            const file_size: u64 = blk: {
                const st = s.file.stat() catch break :blk 0;
                break :blk st.size;
            };
            out.print("  {s}\n", .{s.id});
            out.print("    Path: {s}\n", .{s.path});
            out.print("    Format: {s}\n", .{s.detected_format.label()});
            out.print("    Offset: {d} / {d} bytes\n", .{ s.read_offset, file_size });
            out.print("    Lines seen: {d}\n\n", .{s.line_count});
        }

        return out.toOwnedSlice();
    }

    // ── log_stop ────────────────────────────────────────────────────────

    fn toolStop(self: *LogServer, arguments: ?json.Value) ![]const u8 {
        const args = arguments orelse return try self.allocator.dupe(u8, "Error: missing arguments (required: session)");

        const session_id = getStr(args, "session") orelse
            return try self.allocator.dupe(u8, "Error: 'session' is required");

        debug_log.log("log_stop: session={s}", .{session_id});

        const kv = self.sessions.fetchRemove(session_id);
        if (kv) |entry| {
            var session = entry.value;
            self.allocator.free(entry.key);
            session.deinit(self.allocator);
            return try std.fmt.allocPrint(self.allocator, "Session '{s}' stopped.", .{session_id});
        }

        return try std.fmt.allocPrint(self.allocator, "Error: session '{s}' not found", .{session_id});
    }
};

// ── Tool Definitions ────────────────────────────────────────────────────

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub const tool_definitions = [_]ToolDef{
    .{
        .name = "log_watch",
        .description = "Start watching a log file. Opens the file and sets up a cursor for incremental reading. Returns session ID, file metadata, and optional initial tail lines.",
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the log file (absolute or relative to project root)"},"from_end":{"type":"boolean","description":"Start reading from end of file (default: true). Set false to read from beginning."},"tail_lines":{"type":"number","description":"Number of lines to return from end of file on start (default: 50)"}},"required":["path"]}
        ,
    },
    .{
        .name = "log_tail",
        .description = "Read new lines since last read from a watched log file. Advances the cursor. Supports level filtering and pattern matching.",
        .input_schema =
        \\{"type":"object","properties":{"session":{"type":"string","description":"Session ID from log_watch"},"max_lines":{"type":"number","description":"Maximum lines to return (default: 200)"},"level":{"type":"string","description":"Minimum log level filter: TRACE, DEBUG, INFO, WARN, ERROR, FATAL"},"pattern":{"type":"string","description":"Text pattern to filter lines (substring match)"}},"required":["session"]}
        ,
    },
    .{
        .name = "log_search",
        .description = "Search entire log file for matching lines. Does NOT advance the tail cursor. Supports level filtering and time range filtering.",
        .input_schema =
        \\{"type":"object","properties":{"session":{"type":"string","description":"Session ID from log_watch"},"pattern":{"type":"string","description":"Text pattern to search for (substring match)"},"level":{"type":"string","description":"Minimum log level filter"},"max_results":{"type":"number","description":"Maximum results (default: 50)"},"context_lines":{"type":"number","description":"Lines of context around each match (default: 0)"}},"required":["session","pattern"]}
        ,
    },
    .{
        .name = "log_errors",
        .description = "Extract and deduplicate errors from the log file. Groups by error fingerprint, collects stack traces, reports counts and first/last occurrence.",
        .input_schema =
        \\{"type":"object","properties":{"session":{"type":"string","description":"Session ID from log_watch"},"max_errors":{"type":"number","description":"Maximum unique errors to return (default: 20)"}},"required":["session"]}
        ,
    },
    .{
        .name = "log_overview",
        .description = "Get file metadata and summary: size, line count, detected format, log level distribution, and head/tail samples.",
        .input_schema =
        \\{"type":"object","properties":{"session":{"type":"string","description":"Session ID from log_watch"}},"required":["session"]}
        ,
    },
    .{
        .name = "log_sessions",
        .description = "List all active log watching sessions with their file paths, formats, and cursor positions.",
        .input_schema =
        \\{"type":"object","properties":{}}
        ,
    },
    .{
        .name = "log_stop",
        .description = "Stop watching a log file and close the session.",
        .input_schema =
        \\{"type":"object","properties":{"session":{"type":"string","description":"Session ID to stop"}},"required":["session"]}
        ,
    },
};

// ── Format Detection ────────────────────────────────────────────────────

fn detectFormat(allocator: Allocator, data: []const u8) LogFormat {
    if (data.len == 0) return .plaintext;

    var json_count: usize = 0;
    var logfmt_count: usize = 0;
    var ts_count: usize = 0;
    var total: usize = 0;

    var iter = std.mem.splitSequence(u8, data, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        total += 1;
        if (total > 50) break;

        // JSON check: starts with '{' and is valid JSON
        if (line[0] == '{') {
            if ((json.validate(allocator, line) catch false))
                json_count += 1;
        }

        // Logfmt check
        if (containsLogfmt(line)) {
            logfmt_count += 1;
        }

        // Timestamp check
        if (startsWithTimestamp(line)) {
            ts_count += 1;
        }
    }

    if (total == 0) return .plaintext;

    if (json_count * 100 / total >= 80) return .json_lines;
    if (logfmt_count * 100 / total >= 50) return .logfmt;
    if (ts_count * 100 / total >= 50) return .timestamped;

    return .plaintext;
}

fn containsLogfmt(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "level=") != null) return true;
    if (std.mem.indexOf(u8, line, "msg=") != null) return true;

    var pairs: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const eq_pos = std.mem.indexOfScalarPos(u8, line, i, '=') orelse break;
        if (eq_pos > i and eq_pos + 1 < line.len) {
            if (eq_pos > 0 and isWordChar(line[eq_pos - 1])) {
                pairs += 1;
            }
        }
        i = eq_pos + 1;
    }
    return pairs >= 3;
}

fn startsWithTimestamp(line: []const u8) bool {
    if (line.len < 8) return false;

    // ISO 8601: 2024-03-15T... or 2024-03-15 ...
    if (line.len >= 10 and
        std.ascii.isDigit(line[0]) and std.ascii.isDigit(line[1]) and
        std.ascii.isDigit(line[2]) and std.ascii.isDigit(line[3]) and
        line[4] == '-' and std.ascii.isDigit(line[5]) and std.ascii.isDigit(line[6]) and
        line[7] == '-' and std.ascii.isDigit(line[8]) and std.ascii.isDigit(line[9]))
    {
        return true;
    }

    // Syslog: Jan 15 10:30:00
    if (line.len >= 15 and std.ascii.isUpper(line[0]) and std.ascii.isLower(line[1]) and
        std.ascii.isLower(line[2]) and line[3] == ' ')
    {
        return true;
    }

    // Nginx/Apache CLF: [10/Oct/2000:13:55:36
    if (line[0] == '[' and line.len >= 12 and std.ascii.isDigit(line[1])) {
        return true;
    }

    // Rails: D, [ or I, [
    if (line.len >= 3 and line[1] == ',' and line[2] == ' ') {
        const c = line[0];
        if (c == 'D' or c == 'I' or c == 'W' or c == 'E' or c == 'F') {
            return true;
        }
    }

    return false;
}

// ── Level Extraction ────────────────────────────────────────────────────

fn extractLevel(line: []const u8, format: LogFormat) ?LogLevel {
    return switch (format) {
        .json_lines => extractLevelJson(line),
        .logfmt => extractLevelLogfmt(line),
        .timestamped => extractLevelFromText(line),
        .plaintext => extractLevelFromText(line),
    };
}

fn extractLevelJson(line: []const u8) ?LogLevel {
    const level_keys = [_][]const u8{ "\"level\"", "\"severity\"", "\"lvl\"", "\"log_level\"" };
    for (level_keys) |key| {
        if (std.mem.indexOf(u8, line, key)) |pos| {
            var i = pos + key.len;
            while (i < line.len and (line[i] == ':' or line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            if (i >= line.len) continue;

            if (line[i] == '"') {
                i += 1;
                const start = i;
                while (i < line.len and line[i] != '"') : (i += 1) {}
                if (i > start) {
                    return LogLevel.fromString(line[start..i]);
                }
            } else if (std.ascii.isDigit(line[i])) {
                return LogLevel.fromString(line[i .. i + 1]);
            }
        }
    }
    return null;
}

fn extractLevelLogfmt(line: []const u8) ?LogLevel {
    if (std.mem.indexOf(u8, line, "level=")) |pos| {
        var i = pos + "level=".len;
        if (i < line.len and line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            return LogLevel.fromString(line[start..i]);
        }
        const start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        if (i > start) {
            return LogLevel.fromString(line[start..i]);
        }
    }
    return null;
}

fn extractLevelFromText(line: []const u8) ?LogLevel {
    const keywords = [_]struct { text: []const u8, level: LogLevel }{
        .{ .text = "FATAL", .level = .fatal },
        .{ .text = "PANIC", .level = .fatal },
        .{ .text = "CRITICAL", .level = .fatal },
        .{ .text = "EMERG", .level = .fatal },
        .{ .text = "ERROR", .level = .err },
        .{ .text = "ERR", .level = .err },
        .{ .text = "WARNING", .level = .warn },
        .{ .text = "WARN", .level = .warn },
        .{ .text = "INFO", .level = .info },
        .{ .text = "DEBUG", .level = .debug },
        .{ .text = "TRACE", .level = .trace },
    };

    for (keywords) |kw| {
        if (indexOfIgnoreCase(line, kw.text)) |pos| {
            const before_ok = pos == 0 or !std.ascii.isAlphanumeric(line[pos - 1]);
            const after_pos = pos + kw.text.len;
            const after_ok = after_pos >= line.len or !std.ascii.isAlphanumeric(line[after_pos]);
            if (before_ok and after_ok) return kw.level;
        }
    }

    return null;
}

// ── Line Filtering ──────────────────────────────────────────────────────

const FilterResult = struct {
    lines: []const u8,
    total_lines: usize,
    filtered_count: usize,
};

fn filterLines(allocator: Allocator, data: []const u8, min_level: ?LogLevel, pattern: ?[]const u8, max_lines: usize, format: LogFormat) !FilterResult {
    var out = Output.init(allocator);
    errdefer out.deinit();

    var total: usize = 0;
    var matched: usize = 0;

    var iter = std.mem.splitSequence(u8, data, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        total += 1;

        if (min_level) |ml| {
            const line_level = extractLevel(line, format) orelse .info;
            if (!line_level.meetsMinimum(ml)) continue;
        }

        if (pattern) |pat| {
            if (std.mem.indexOf(u8, line, pat) == null and
                indexOfIgnoreCase(line, pat) == null)
                continue;
        }

        if (matched >= max_lines) continue;

        out.append(line);
        out.appendByte('\n');
        matched += 1;
    }

    return .{
        .lines = try out.toOwnedSlice(),
        .total_lines = total,
        .filtered_count = matched,
    };
}

// ── Search ──────────────────────────────────────────────────────────────

fn searchLines(allocator: Allocator, data: []const u8, pattern: []const u8, min_level: ?LogLevel, max_results: usize, context_lines: usize, format: LogFormat) ![]const u8 {
    // Collect lines
    var lines_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines_list.deinit(allocator);

    var iter = std.mem.splitSequence(u8, data, "\n");
    while (iter.next()) |line| {
        try lines_list.append(allocator, line);
    }

    const lines = lines_list.items;

    var out = Output.init(allocator);
    errdefer out.deinit();

    var result_count: usize = 0;
    var last_printed_end: usize = 0;

    for (lines, 0..) |line, i| {
        if (result_count >= max_results) break;
        if (line.len == 0) continue;

        if (std.mem.indexOf(u8, line, pattern) == null and
            indexOfIgnoreCase(line, pattern) == null) continue;

        if (min_level) |ml| {
            const line_level = extractLevel(line, format) orelse .info;
            if (!line_level.meetsMinimum(ml)) continue;
        }

        result_count += 1;

        const ctx_start = if (i > context_lines) i - context_lines else 0;
        const ctx_end = @min(i + context_lines + 1, lines.len);

        if (result_count > 1 and ctx_start > last_printed_end) {
            out.append("---\n");
        }

        const print_start = if (ctx_start > last_printed_end) ctx_start else last_printed_end;

        for (lines[print_start..ctx_end], print_start..) |ctx_line, line_num| {
            const is_match = line_num == i;
            if (is_match) {
                out.print(">> {d}: {s}\n", .{ line_num + 1, ctx_line });
            } else {
                out.print("   {d}: {s}\n", .{ line_num + 1, ctx_line });
            }
        }

        last_printed_end = ctx_end;
    }

    if (result_count == 0) {
        out.print("No matches found for '{s}'.", .{pattern});
    } else {
        // Prepend count header
        const content = try out.toOwnedSlice();
        defer allocator.free(content);
        var header_out = Output.init(allocator);
        errdefer header_out.deinit();
        header_out.print("{d} matches found:\n\n", .{result_count});
        header_out.append(content);
        return header_out.toOwnedSlice();
    }

    return out.toOwnedSlice();
}

// ── Error Extraction ────────────────────────────────────────────────────

const ErrorEntry = struct {
    fingerprint: u64,
    message: []const u8,
    stack_trace: []const u8,
    count: usize,
    first_line: usize,
    last_line: usize,
};

fn extractErrors(allocator: Allocator, data: []const u8, max_errors: usize, format: LogFormat) ![]const u8 {
    var all_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_lines.deinit(allocator);

    var line_iter = std.mem.splitSequence(u8, data, "\n");
    while (line_iter.next()) |line| {
        try all_lines.append(allocator, line);
    }
    const lines = all_lines.items;

    var error_map = std.AutoHashMapUnmanaged(u64, ErrorEntry).empty;
    defer {
        var map_iter = error_map.iterator();
        while (map_iter.next()) |entry| {
            if (entry.value_ptr.stack_trace.len > 0) {
                allocator.free(entry.value_ptr.stack_trace);
            }
        }
        error_map.deinit(allocator);
    }
    var error_order: std.ArrayListUnmanaged(u64) = .empty;
    defer error_order.deinit(allocator);

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (line.len == 0) continue;

        const level = extractLevel(line, format) orelse continue;
        if (!level.meetsMinimum(.err)) continue;

        // Collect stack trace lines
        var stack_end = i + 1;
        while (stack_end < lines.len and isStackTraceLine(lines[stack_end])) : (stack_end += 1) {}

        // Build stack trace text
        var stack_out = Output.init(allocator);
        defer stack_out.deinit();
        if (stack_end > i + 1) {
            for (lines[i + 1 .. stack_end]) |stack_line| {
                stack_out.append(stack_line);
                stack_out.appendByte('\n');
            }
        }

        const fp = fingerprintLine(line);

        const gop = try error_map.getOrPut(allocator, fp);
        if (gop.found_existing) {
            gop.value_ptr.count += 1;
            gop.value_ptr.last_line = i;
        } else {
            const stack_text = if (stack_out.buf.items.len > 0)
                try allocator.dupe(u8, stack_out.buf.items)
            else
                @as([]const u8, "");
            gop.value_ptr.* = .{
                .fingerprint = fp,
                .message = line,
                .stack_trace = stack_text,
                .count = 1,
                .first_line = i,
                .last_line = i,
            };
            try error_order.append(allocator, fp);
        }

        if (stack_end > i + 1) {
            i = stack_end - 1;
        }
    }

    var out = Output.init(allocator);
    errdefer out.deinit();

    if (error_order.items.len == 0) {
        out.append("No errors found.");
        return out.toOwnedSlice();
    }

    const shown = @min(error_order.items.len, max_errors);
    out.print("{d} unique errors found ({d} shown):\n\n", .{ error_order.items.len, shown });

    for (error_order.items[0..shown], 1..) |fp, idx| {
        const entry = error_map.get(fp).?;
        out.print("--- Error {d} ({d}x, lines {d}-{d}) ---\n", .{ idx, entry.count, entry.first_line + 1, entry.last_line + 1 });
        out.print("{s}\n", .{entry.message});
        if (entry.stack_trace.len > 0) {
            out.print("{s}", .{entry.stack_trace});
        }
        out.appendByte('\n');
    }

    return out.toOwnedSlice();
}

fn isStackTraceLine(line: []const u8) bool {
    if (line.len == 0) return false;

    // Generic: indented continuation line
    if (line[0] == ' ' or line[0] == '\t') return true;

    // Java: "Caused by:"
    if (std.mem.startsWith(u8, line, "Caused by:")) return true;

    // Python: "Traceback"
    if (std.mem.startsWith(u8, line, "Traceback")) return true;

    // Go: "goroutine"
    if (std.mem.startsWith(u8, line, "goroutine ")) return true;

    return false;
}

fn fingerprintLine(line: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (std.ascii.isDigit(c)) {
            hasher.update("N");
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '.' or line[i] == '-' or line[i] == ':')) : (i += 1) {}
        } else if (c == '/' and i + 1 < line.len and (std.ascii.isAlphanumeric(line[i + 1]) or line[i + 1] == '.')) {
            hasher.update("P");
            while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\n') : (i += 1) {}
        } else {
            hasher.update(line[i .. i + 1]);
            i += 1;
        }
    }

    return hasher.final();
}

// ── Utility Functions ───────────────────────────────────────────────────

fn readFileTail(allocator: Allocator, file: std.fs.File, file_size: u64) ![]const u8 {
    if (file_size == 0) return try allocator.dupe(u8, "");

    const read_size: usize = @intCast(@min(file_size, 64 * 1024));
    const offset = file_size - read_size;

    const buf = try allocator.alloc(u8, read_size);
    errdefer allocator.free(buf);

    file.seekTo(offset) catch return error.SeekFailed;
    const bytes_read = file.readAll(buf) catch return error.ReadFailed;

    if (bytes_read < read_size) {
        // Shrink buffer — realloc may not be available on all allocators, dupe instead
        const result = try allocator.dupe(u8, buf[0..bytes_read]);
        allocator.free(buf);
        return result;
    }
    return buf;
}

const TailResult = struct {
    text: []const u8,
    count: usize,
};

fn extractLastNLines(allocator: Allocator, data: []const u8, n: usize) !TailResult {
    if (data.len == 0) return .{ .text = "", .count = 0 };

    // Find newline positions
    var nl_count: usize = 0;
    var positions: std.ArrayListUnmanaged(usize) = .empty;
    defer positions.deinit(allocator);

    for (data, 0..) |c, idx| {
        if (c == '\n') {
            try positions.append(allocator, idx);
            nl_count += 1;
        }
    }

    if (nl_count == 0) {
        return .{
            .text = try allocator.dupe(u8, data),
            .count = 1,
        };
    }

    // Skip (nl_count - n) lines from the beginning.
    // The last skipped line ends at positions[nl_count - n - 1].
    const start_idx = if (nl_count > n)
        positions.items[nl_count - n - 1] + 1
    else
        0;

    var end_idx = data.len;
    while (end_idx > start_idx and data[end_idx - 1] == '\n') {
        end_idx -= 1;
    }

    if (end_idx <= start_idx) return .{ .text = "", .count = 0 };

    const count = @min(n, nl_count);
    return .{
        .text = try allocator.dupe(u8, data[start_idx..end_idx]),
        .count = count,
    };
}

fn extractFirstNLines(allocator: Allocator, data: []const u8, n: usize) ![]const u8 {
    if (data.len == 0) return "";

    var count: usize = 0;
    var end: usize = 0;

    for (data, 0..) |c, idx| {
        if (c == '\n') {
            count += 1;
            if (count >= n) {
                end = idx;
                break;
            }
        }
    }

    if (count < n) end = data.len;
    if (end == 0 and data.len > 0) end = data.len;

    return try allocator.dupe(u8, data[0..end]);
}

fn countLines(data: []const u8) usize {
    if (data.len == 0) return 0;
    var count: usize = 0;
    for (data) |c| {
        if (c == '\n') count += 1;
    }
    if (data[data.len - 1] != '\n') count += 1;
    return count;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (asciiEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ── JSON arg helpers ────────────────────────────────────────────────────

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

// ── Tests ───────────────────────────────────────────────────────────────

test "format detection: json_lines" {
    const data =
        \\{"level":"info","msg":"server started","ts":"2024-01-15T10:00:00Z"}
        \\{"level":"error","msg":"connection failed","ts":"2024-01-15T10:00:01Z"}
        \\{"level":"debug","msg":"processing request","ts":"2024-01-15T10:00:02Z"}
    ;
    try std.testing.expectEqual(LogFormat.json_lines, detectFormat(std.testing.allocator, data));
}

test "format detection: logfmt" {
    const data =
        \\time=2024-01-15T10:00:00Z level=info msg="server started" port=8080
        \\time=2024-01-15T10:00:01Z level=error msg="connection failed" err="timeout"
        \\time=2024-01-15T10:00:02Z level=debug msg="processing request" id=42
    ;
    try std.testing.expectEqual(LogFormat.logfmt, detectFormat(std.testing.allocator, data));
}

test "format detection: timestamped" {
    const data =
        \\2024-01-15 10:00:00,123 INFO server started
        \\2024-01-15 10:00:01,456 ERROR connection failed
        \\2024-01-15 10:00:02,789 DEBUG processing request
    ;
    try std.testing.expectEqual(LogFormat.timestamped, detectFormat(std.testing.allocator, data));
}

test "format detection: plaintext" {
    const data =
        \\starting server
        \\listening on port 8080
        \\ready for connections
    ;
    try std.testing.expectEqual(LogFormat.plaintext, detectFormat(std.testing.allocator, data));
}

test "level extraction: json" {
    const line =
        \\{"level":"error","msg":"something failed"}
    ;
    try std.testing.expectEqual(LogLevel.err, extractLevelJson(line));
}

test "level extraction: logfmt" {
    const line = "time=2024-01-15T10:00:00Z level=warn msg=\"low disk space\"";
    try std.testing.expectEqual(LogLevel.warn, extractLevelLogfmt(line));
}

test "level extraction: text" {
    try std.testing.expectEqual(LogLevel.err, extractLevelFromText("2024-01-15 ERROR something failed"));
    try std.testing.expectEqual(LogLevel.info, extractLevelFromText("2024-01-15 INFO started"));
    try std.testing.expectEqual(LogLevel.fatal, extractLevelFromText("FATAL: out of memory"));
    try std.testing.expectEqual(LogLevel.warn, extractLevelFromText("[WARNING] disk space low"));
}

test "level ordering" {
    try std.testing.expect(LogLevel.err.meetsMinimum(.warn));
    try std.testing.expect(LogLevel.err.meetsMinimum(.err));
    try std.testing.expect(!LogLevel.info.meetsMinimum(.warn));
    try std.testing.expect(LogLevel.fatal.meetsMinimum(.err));
    try std.testing.expect(!LogLevel.debug.meetsMinimum(.info));
}

test "stack trace detection" {
    try std.testing.expect(isStackTraceLine("    at module.exports (/app/index.js:42:15)"));
    try std.testing.expect(isStackTraceLine("\tat com.example.MyClass.method(MyClass.java:42)"));
    try std.testing.expect(isStackTraceLine("Caused by: java.lang.NullPointerException"));
    try std.testing.expect(isStackTraceLine("  File \"/app/main.py\", line 42, in main"));
    try std.testing.expect(!isStackTraceLine("ERROR: something went wrong"));
    try std.testing.expect(!isStackTraceLine("2024-01-15 10:00:00 INFO started"));
}

test "fingerprinting normalizes numbers" {
    const fp1 = fingerprintLine("Error at line 42: connection timeout after 30s");
    const fp2 = fingerprintLine("Error at line 99: connection timeout after 60s");
    try std.testing.expectEqual(fp1, fp2);
}

test "fingerprinting distinguishes different errors" {
    const fp1 = fingerprintLine("Error: connection refused");
    const fp2 = fingerprintLine("Error: file not found");
    try std.testing.expect(fp1 != fp2);
}

test "countLines" {
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc\n"));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
    try std.testing.expectEqual(@as(usize, 1), countLines("hello"));
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
}

test "extractLastNLines" {
    const data = "line1\nline2\nline3\nline4\nline5\n";
    const result = try extractLastNLines(std.testing.allocator, data, 3);
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqualStrings("line3\nline4\nline5", result.text);
}

test "extractFirstNLines" {
    const data = "line1\nline2\nline3\nline4\nline5\n";
    const result = try extractFirstNLines(std.testing.allocator, data, 3);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2\nline3", result);
}

test "session lifecycle" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.log", .{});
    try file.writeAll("2024-01-15 10:00:00 INFO Started\n2024-01-15 10:00:01 ERROR Failed\n2024-01-15 10:00:02 INFO Recovered\n");
    file.close();

    var server = LogServer.init(std.testing.allocator);
    defer server.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try tmp_dir.dir.realpath("test.log", &path_buf);

    // Build watch arguments
    var watch_args_map = json.ObjectMap.init(std.testing.allocator);
    defer watch_args_map.deinit();
    try watch_args_map.put("path", .{ .string = abs_path });
    try watch_args_map.put("from_end", .{ .bool = true });
    try watch_args_map.put("tail_lines", .{ .integer = 10 });
    const watch_args = json.Value{ .object = watch_args_map };

    const watch_result = try server.callTool("log_watch", watch_args);
    defer std.testing.allocator.free(watch_result);

    try std.testing.expect(std.mem.indexOf(u8, watch_result, "Session started: log_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, watch_result, "timestamped") != null);

    try std.testing.expectEqual(@as(u32, 1), server.sessions.count());

    // Test sessions list
    const sessions_result = try server.callTool("log_sessions", null);
    defer std.testing.allocator.free(sessions_result);
    try std.testing.expect(std.mem.indexOf(u8, sessions_result, "log_1") != null);

    // Append new lines
    const append_file = try tmp_dir.dir.openFile("test.log", .{ .mode = .write_only });
    try append_file.seekFromEnd(0);
    try append_file.writeAll("2024-01-15 10:00:03 WARN Something fishy\n2024-01-15 10:00:04 ERROR Crashed\n");
    append_file.close();

    // Test tail
    var tail_args_map = json.ObjectMap.init(std.testing.allocator);
    defer tail_args_map.deinit();
    try tail_args_map.put("session", .{ .string = "log_1" });
    const tail_args = json.Value{ .object = tail_args_map };

    const tail_result = try server.callTool("log_tail", tail_args);
    defer std.testing.allocator.free(tail_result);

    try std.testing.expect(std.mem.indexOf(u8, tail_result, "Something fishy") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail_result, "Crashed") != null);

    // Test stop
    var stop_args_map = json.ObjectMap.init(std.testing.allocator);
    defer stop_args_map.deinit();
    try stop_args_map.put("session", .{ .string = "log_1" });
    const stop_args = json.Value{ .object = stop_args_map };

    const stop_result = try server.callTool("log_stop", stop_args);
    defer std.testing.allocator.free(stop_result);

    try std.testing.expect(std.mem.indexOf(u8, stop_result, "stopped") != null);
    try std.testing.expectEqual(@as(u32, 0), server.sessions.count());
}

test "log_errors deduplication" {
    const data =
        \\2024-01-15 10:00:00 ERROR Connection refused to host 192.168.1.1:5432
        \\    at pg.connect(db.js:42)
        \\    at main(index.js:10)
        \\2024-01-15 10:00:01 INFO Retrying...
        \\2024-01-15 10:00:02 ERROR Connection refused to host 192.168.1.2:5432
        \\    at pg.connect(db.js:42)
        \\    at main(index.js:10)
        \\2024-01-15 10:00:03 ERROR File not found: /tmp/data.csv
    ;

    const result = try extractErrors(std.testing.allocator, data, 20, .timestamped);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "2 unique errors") != null);
}

test "log_search with context" {
    const data = "line1\nline2\nERROR here\nline4\nline5\n";

    const result = try searchLines(std.testing.allocator, data, "ERROR", null, 50, 1, .plaintext);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ERROR here") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "line4") != null);
}

test "filter by level" {
    const data = "2024-01-15 DEBUG verbose stuff\n2024-01-15 INFO started\n2024-01-15 ERROR failed\n2024-01-15 WARN careful\n";
    const result = try filterLines(std.testing.allocator, data, .warn, null, 100, .timestamped);
    defer std.testing.allocator.free(result.lines);

    try std.testing.expectEqual(@as(usize, 2), result.filtered_count);
    try std.testing.expect(std.mem.indexOf(u8, result.lines, "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.lines, "WARN") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.lines, "DEBUG") == null);
}
