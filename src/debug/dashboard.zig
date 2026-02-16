const std = @import("std");
const types = @import("types.zig");
const session_mod = @import("session.zig");

// ── ANSI Styles ─────────────────────────────────────────────────────────

const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Unicode Glyphs ──────────────────────────────────────────────────────

const bullet_filled = "\xE2\x97\x8F"; // ●
const check = "\xE2\x9C\x93"; // ✓
const cross = "\xE2\x9C\x97"; // ✗

// ── Box-Drawing Characters ──────────────────────────────────────────────

const hh = "\xE2\x94\x80"; // ─
const vv = "\xE2\x94\x82"; // │
const ct = "\xE2\x94\x8C"; // ┌
const cb = "\xE2\x94\x94"; // └
const tr = "\xE2\x94\x90"; // ┐
const br = "\xE2\x94\x98"; // ┘
const h3 = hh ++ hh ++ hh;
const h4 = h3 ++ hh;

// ── Sub-types ───────────────────────────────────────────────────────────

pub const SessionInfo = struct {
    id: [32]u8 = undefined,
    id_len: usize = 0,
    program: [128]u8 = undefined,
    program_len: usize = 0,
    status: session_mod.Session.Status = .launching,
    driver_type: [8]u8 = undefined,
    driver_type_len: usize = 0,

    fn idSlice(self: *const SessionInfo) []const u8 {
        return self.id[0..self.id_len];
    }

    fn programSlice(self: *const SessionInfo) []const u8 {
        return self.program[0..self.program_len];
    }

    fn driverTypeSlice(self: *const SessionInfo) []const u8 {
        return self.driver_type[0..self.driver_type_len];
    }
};

pub const BpInfo = struct {
    id: u32 = 0,
    file: [128]u8 = undefined,
    file_len: usize = 0,
    line: u32 = 0,
    verified: bool = false,

    fn fileSlice(self: *const BpInfo) []const u8 {
        return self.file[0..self.file_len];
    }
};

pub const StopSnapshot = struct {
    session_id: [32]u8 = undefined,
    session_id_len: usize = 0,
    reason: [16]u8 = undefined,
    reason_len: usize = 0,
    location: [128]u8 = undefined,
    location_len: usize = 0,
    exit_code: ?i32 = null,
    locals_summary: [64]u8 = undefined,
    locals_summary_len: usize = 0,
};

pub const LogEntry = struct {
    tool_name: [20]u8 = undefined,
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

const LOG_SIZE = 16;

pub const RingLog = struct {
    entries: [LOG_SIZE]LogEntry = [_]LogEntry{.{}} ** LOG_SIZE,
    head: usize = 0,
    count: usize = 0,

    fn push(self: *RingLog, entry: LogEntry) void {
        self.entries[self.head] = entry;
        self.head = (self.head + 1) % LOG_SIZE;
        if (self.count < LOG_SIZE) self.count += 1;
    }

    /// Iterate entries oldest to newest.
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

// ── Dashboard ───────────────────────────────────────────────────────────

pub const Dashboard = struct {
    enabled: bool,
    rendered_lines: usize,
    sessions: [8]SessionInfo,
    session_count: usize,
    breakpoints: [32]BpInfo,
    bp_count: usize,
    last_stop: ?StopSnapshot,
    log: RingLog,

    pub fn init() Dashboard {
        return .{
            .enabled = isStderrTty(),
            .rendered_lines = 0,
            .sessions = [_]SessionInfo{.{}} ** 8,
            .session_count = 0,
            .breakpoints = [_]BpInfo{.{}} ** 32,
            .bp_count = 0,
            .last_stop = null,
            .log = .{},
        };
    }

    // ── Update methods ──────────────────────────────────────────────

    pub fn onLaunch(self: *Dashboard, session_id: []const u8, program: []const u8, driver_type: []const u8) void {
        if (self.session_count < 8) {
            var info: SessionInfo = .{};
            copyInto(&info.id, &info.id_len, session_id);
            copyInto(&info.program, &info.program_len, program);
            copyInto(&info.driver_type, &info.driver_type_len, driver_type);
            info.status = .stopped;
            self.sessions[self.session_count] = info;
            self.session_count += 1;
        }
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_launch");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} created, stopped at entry", .{
            truncate(session_id, 20),
        }) catch "session created";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onBreakpoint(self: *Dashboard, action: []const u8, bp: types.BreakpointInfo) void {
        if (std.mem.eql(u8, action, "set")) {
            if (self.bp_count < 32) {
                var info: BpInfo = .{};
                info.id = bp.id;
                copyInto(&info.file, &info.file_len, bp.file);
                info.line = bp.line;
                info.verified = bp.verified;
                self.breakpoints[self.bp_count] = info;
                self.bp_count += 1;
            }
            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "debug_breakpoint");
            var buf: [80]u8 = undefined;
            const summary = std.fmt.bufPrint(&buf, "set {s}:{d}", .{
                truncate(bp.file, 40), bp.line,
            }) catch "breakpoint set";
            copyInto(&entry.summary, &entry.summary_len, summary);
            self.log.push(entry);
        } else if (std.mem.eql(u8, action, "remove")) {
            self.removeBp(bp.id);
            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "debug_breakpoint");
            var buf: [80]u8 = undefined;
            const summary = std.fmt.bufPrint(&buf, "removed breakpoint {d}", .{bp.id}) catch "breakpoint removed";
            copyInto(&entry.summary, &entry.summary_len, summary);
            self.log.push(entry);
        } else {
            var entry: LogEntry = .{};
            copyInto(&entry.tool_name, &entry.tool_name_len, "debug_breakpoint");
            copyInto(&entry.summary, &entry.summary_len, "listed breakpoints");
            self.log.push(entry);
        }
    }

    pub fn onRun(self: *Dashboard, session_id: []const u8, action: []const u8, state: types.StopState) void {
        // Update session status
        for (self.sessions[0..self.session_count]) |*s| {
            if (std.mem.eql(u8, s.idSlice(), session_id)) {
                s.status = if (state.stop_reason == .exit) .terminated else .stopped;
                break;
            }
        }

        // Update last_stop
        var snap: StopSnapshot = .{};
        copyInto(&snap.session_id, &snap.session_id_len, session_id);
        const reason = @tagName(state.stop_reason);
        copyInto(&snap.reason, &snap.reason_len, reason);
        if (state.location) |loc| {
            var buf: [128]u8 = undefined;
            const loc_str = std.fmt.bufPrint(&buf, "{s}:{d}", .{ truncate(loc.file, 80), loc.line }) catch "";
            copyInto(&snap.location, &snap.location_len, loc_str);
        }
        snap.exit_code = state.exit_code;
        if (state.locals.len > 0) {
            var buf: [64]u8 = undefined;
            const locals_str = std.fmt.bufPrint(&buf, "{d} variable(s)", .{state.locals.len}) catch "";
            copyInto(&snap.locals_summary, &snap.locals_summary_len, locals_str);
        }
        self.last_stop = snap;

        // Log entry
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_run");
        var buf: [80]u8 = undefined;
        if (state.exit_code) |code| {
            const summary = std.fmt.bufPrint(&buf, "{s} \xE2\x86\x92 {s} (code {d})", .{
                truncate(action, 12), reason, code,
            }) catch "run completed";
            copyInto(&entry.summary, &entry.summary_len, summary);
        } else {
            const summary = std.fmt.bufPrint(&buf, "{s} \xE2\x86\x92 {s}", .{
                truncate(action, 12), reason,
            }) catch "run completed";
            copyInto(&entry.summary, &entry.summary_len, summary);
        }
        self.log.push(entry);

        // Log any log point messages
        for (state.log_messages) |msg| {
            var log_entry: LogEntry = .{};
            copyInto(&log_entry.tool_name, &log_entry.tool_name_len, "log_point");
            copyInto(&log_entry.summary, &log_entry.summary_len, truncate(msg, 76));
            self.log.push(log_entry);
        }
    }

    pub fn onInspect(self: *Dashboard, session_id: []const u8, expression: []const u8, result: []const u8) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_inspect");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} \xE2\x86\x92 \"{s}\"", .{
            truncate(expression, 20), truncate(result, 30),
        }) catch "inspect completed";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onStop(self: *Dashboard, session_id: []const u8) void {
        // Remove session
        var i: usize = 0;
        while (i < self.session_count) {
            if (std.mem.eql(u8, self.sessions[i].idSlice(), session_id)) {
                // Shift remaining sessions down
                var j: usize = i;
                while (j + 1 < self.session_count) : (j += 1) {
                    self.sessions[j] = self.sessions[j + 1];
                }
                self.session_count -= 1;
                break;
            }
            i += 1;
        }

        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_stop");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} destroyed", .{
            truncate(session_id, 20),
        }) catch "session destroyed";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onStackTrace(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_stacktrace");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} frame(s)", .{count}) catch "stack trace";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onSetVariable(self: *Dashboard, session_id: []const u8, variable: []const u8, value: []const u8) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_set_variable");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} = {s}", .{
            truncate(variable, 20), truncate(value, 30),
        }) catch "variable set";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onThreads(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_threads");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} thread(s)", .{count}) catch "threads listed";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onMemory(self: *Dashboard, session_id: []const u8, action: []const u8, address: []const u8) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_memory");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} @ {s}", .{
            truncate(action, 8), truncate(address, 20),
        }) catch "memory operation";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onDisassemble(self: *Dashboard, session_id: []const u8, address: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_disassemble");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} insn @ {s}", .{
            count, truncate(address, 20),
        }) catch "disassembly";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onAttach(self: *Dashboard, session_id: []const u8, pid: i64) void {
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_attach");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} attached to pid {d}", .{
            truncate(session_id, 16), pid,
        }) catch "attached";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onScopes(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_scopes");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} scope(s)", .{count}) catch "scopes listed";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onWatchpoint(self: *Dashboard, session_id: []const u8, variable: []const u8, access_type: []const u8) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_watchpoint");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} ({s})", .{
            truncate(variable, 30), truncate(access_type, 10),
        }) catch "watchpoint set";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onCompletions(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_completions");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} completion(s)", .{count}) catch "completions";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onModules(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_modules");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} module(s)", .{count}) catch "modules";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onRestartFrame(self: *Dashboard, session_id: []const u8, frame_id: u32) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_restart_fr");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "restarted frame {d}", .{frame_id}) catch "frame restarted";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onCapabilities(self: *Dashboard, session_id: []const u8) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_capabilities");
        copyInto(&entry.summary, &entry.summary_len, "queried capabilities");
        self.log.push(entry);
    }

    pub fn onExceptionInfo(self: *Dashboard, session_id: []const u8) void {
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_exception_info");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "exception info for {s}", .{
            truncate(session_id, 20),
        }) catch "exception info";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onRegisters(self: *Dashboard, session_id: []const u8, count: usize) void {
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_registers");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} registers for {s}", .{
            count, truncate(session_id, 20),
        }) catch "registers read";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onInstructionBreakpoint(self: *Dashboard, session_id: []const u8, address: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_insn_bp");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} insn bp @ {s}", .{
            count, truncate(address, 30),
        }) catch "instruction breakpoint";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onStepInTargets(self: *Dashboard, session_id: []const u8, frame_id: u32, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_step_targets");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} target(s) for frame {d}", .{
            count, frame_id,
        }) catch "step-in targets";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onBreakpointLocations(self: *Dashboard, session_id: []const u8, source: []const u8, line: u32, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_bp_locations");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} location(s) @ {s}:{d}", .{
            count, truncate(source, 30), line,
        }) catch "breakpoint locations";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onCancel(self: *Dashboard, session_id: []const u8) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_cancel");
        copyInto(&entry.summary, &entry.summary_len, "request cancelled");
        self.log.push(entry);
    }

    pub fn onTerminateThreads(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_term_threads");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} thread(s) terminated", .{count}) catch "threads terminated";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onRestart(self: *Dashboard, session_id: []const u8) void {
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_restart");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{s} restarted", .{
            truncate(session_id, 20),
        }) catch "session restarted";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onLoadedSources(self: *Dashboard, session_id: []const u8, count: usize) void {
        _ = session_id;
        var entry: LogEntry = .{};
        copyInto(&entry.tool_name, &entry.tool_name_len, "debug_loaded_src");
        var buf: [80]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "{d} source(s) loaded", .{count}) catch "loaded sources";
        copyInto(&entry.summary, &entry.summary_len, summary);
        self.log.push(entry);
    }

    pub fn onError(self: *Dashboard, method: []const u8, message: []const u8) void {
        var entry: LogEntry = .{ .is_error = true };
        copyInto(&entry.tool_name, &entry.tool_name_len, method);
        copyInto(&entry.summary, &entry.summary_len, truncate(message, 80));
        self.log.push(entry);
    }

    // ── Rendering ───────────────────────────────────────────────────

    pub fn render(self: *Dashboard) void {
        if (!self.enabled) return;

        // Clear previous frame
        clearLines(self.rendered_lines);

        var lines: usize = 0;

        // Header
        stderrWrite("\n");
        lines += 1;
        stderrWrite(cyan);
        stderrWrite("  " ++ ct ++ h4 ++ "  " ++ ct ++ h3 ++ tr ++ "  " ++ ct ++ h4 ++ "\n");
        lines += 1;
        stderrWrite("  " ++ vv ++ "      " ++ vv ++ "   " ++ vv ++ "  " ++ vv ++ "\n");
        lines += 1;
        stderrWrite("  " ++ vv ++ "      " ++ vv ++ "   " ++ vv ++ "  " ++ vv ++ " " ++ hh ++ hh ++ tr ++ "\n");
        lines += 1;
        stderrWrite("  " ++ cb ++ h4 ++ "  " ++ cb ++ h3 ++ br ++ "  " ++ cb ++ h3 ++ br ++ "\n");
        lines += 1;
        stderrWrite(reset);
        stderrWrite(dim ++ "  Debug Server\n" ++ reset);
        lines += 1;
        stderrWrite("\n");
        lines += 1;

        // Session section
        stderrWrite(cyan ++ bold ++ "  Session" ++ reset ++ "\n");
        lines += 1;
        if (self.session_count == 0) {
            stderrWrite(dim ++ "    No active sessions\n" ++ reset);
            lines += 1;
        } else {
            for (self.sessions[0..self.session_count]) |*s| {
                stderrWrite("    " ++ cyan ++ bullet_filled ++ reset ++ " ");
                stderrWrite(bold);
                stderrWrite(s.idSlice());
                stderrWrite(reset ++ "  ");
                stderrWrite(@tagName(s.status));
                stderrWrite("  ");
                stderrWrite(s.programSlice());
                stderrWrite("  " ++ dim ++ "(");
                stderrWrite(s.driverTypeSlice());
                stderrWrite(")" ++ reset ++ "\n");
                lines += 1;
            }
        }
        stderrWrite("\n");
        lines += 1;

        // Breakpoints section
        stderrWrite(cyan ++ bold ++ "  Breakpoints" ++ reset ++ "\n");
        lines += 1;
        if (self.bp_count == 0) {
            stderrWrite(dim ++ "    None\n" ++ reset);
            lines += 1;
        } else {
            for (self.breakpoints[0..self.bp_count]) |*bp| {
                var num_buf: [8]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{bp.id}) catch "?";
                stderrWrite("    ");
                stderrWrite(num_str);
                stderrWrite("  ");
                stderrWrite(bp.fileSlice());
                stderrWrite(":");
                var line_buf: [8]u8 = undefined;
                const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{bp.line}) catch "?";
                stderrWrite(line_str);
                stderrWrite("\n");
                lines += 1;
            }
        }
        stderrWrite("\n");
        lines += 1;

        // State section (only if last_stop is set)
        if (self.last_stop) |*snap| {
            stderrWrite(cyan ++ bold ++ "  State" ++ reset ++ "\n");
            lines += 1;
            stderrWrite("    " ++ bold ++ "Reason" ++ reset ++ "   ");
            stderrWrite(snap.reason[0..snap.reason_len]);
            stderrWrite("\n");
            lines += 1;
            if (snap.exit_code) |code| {
                stderrWrite("    " ++ bold ++ "Code" ++ reset ++ "     ");
                var code_buf: [16]u8 = undefined;
                const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch "?";
                stderrWrite(code_str);
                stderrWrite("\n");
                lines += 1;
            }
            if (snap.location_len > 0) {
                stderrWrite("    " ++ bold ++ "Location" ++ reset ++ " ");
                stderrWrite(snap.location[0..snap.location_len]);
                stderrWrite("\n");
                lines += 1;
            }
            if (snap.locals_summary_len > 0) {
                stderrWrite("    " ++ bold ++ "Locals" ++ reset ++ "   ");
                stderrWrite(snap.locals_summary[0..snap.locals_summary_len]);
                stderrWrite("\n");
                lines += 1;
            }
            stderrWrite("\n");
            lines += 1;
        }

        // Separator
        stderrWrite(dim ++ "  " ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ hh ++ reset ++ "\n");
        lines += 1;
        stderrWrite("\n");
        lines += 1;

        // Activity section
        stderrWrite(cyan ++ bold ++ "  Activity" ++ reset ++ "\n");
        lines += 1;
        if (self.log.count == 0) {
            stderrWrite(dim ++ "    Waiting for requests...\n" ++ reset);
            lines += 1;
        } else {
            var it = self.log.iter();
            while (it.next()) |entry| {
                if (entry.is_error) {
                    stderrWrite("    " ++ cross ++ " ");
                } else {
                    stderrWrite("    " ++ cyan ++ check ++ reset ++ " ");
                }
                stderrWrite(bold);
                // Pad tool name to 16 chars
                const name = entry.toolNameSlice();
                stderrWrite(name);
                if (name.len < 16) {
                    var pad_buf: [16]u8 = undefined;
                    const pad_len = 16 - name.len;
                    @memset(pad_buf[0..pad_len], ' ');
                    stderrWrite(pad_buf[0..pad_len]);
                }
                stderrWrite(reset ++ "  ");
                stderrWrite(entry.summarySlice());
                stderrWrite("\n");
                lines += 1;
            }
        }

        self.rendered_lines = lines;
    }

    // ── Helpers ─────────────────────────────────────────────────────

    fn removeBp(self: *Dashboard, id: u32) void {
        var i: usize = 0;
        while (i < self.bp_count) {
            if (self.breakpoints[i].id == id) {
                var j: usize = i;
                while (j + 1 < self.bp_count) : (j += 1) {
                    self.breakpoints[j] = self.breakpoints[j + 1];
                }
                self.bp_count -= 1;
                return;
            }
            i += 1;
        }
    }
};

// ── I/O Helpers ─────────────────────────────────────────────────────────

fn isStderrTty() bool {
    if (@import("builtin").is_test) return false;
    return std.posix.isatty(std.fs.File.stderr().handle);
}

fn stderrWrite(data: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(data) catch {};
    w.interface.flush() catch {};
}

fn stderrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stderrWrite(msg);
}

fn clearLines(line_count: usize) void {
    if (line_count == 0) return;
    stderrFmt("\x1B[{d}A", .{line_count});
    for (0..line_count) |_| {
        stderrWrite("\x1B[2K\n");
    }
    stderrFmt("\x1B[{d}A", .{line_count});
}

fn copyInto(dest: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    len.* = n;
}

fn truncate(s: []const u8, max: usize) []const u8 {
    return if (s.len <= max) s else s[0..max];
}

// ── Tests ───────────────────────────────────────────────────────────────

test "Dashboard initializes with empty state" {
    const dash = Dashboard.init();
    try std.testing.expectEqual(@as(usize, 0), dash.session_count);
    try std.testing.expectEqual(@as(usize, 0), dash.bp_count);
    try std.testing.expect(dash.last_stop == null);
    try std.testing.expectEqual(@as(usize, 0), dash.log.count);
    try std.testing.expect(!dash.enabled); // false in test mode
}

test "Dashboard onLaunch adds session and logs" {
    var dash = Dashboard.init();
    dash.onLaunch("session-1", "/tmp/test", "native");

    try std.testing.expectEqual(@as(usize, 1), dash.session_count);
    try std.testing.expectEqualStrings("session-1", dash.sessions[0].idSlice());
    try std.testing.expectEqualStrings("/tmp/test", dash.sessions[0].programSlice());
    try std.testing.expectEqualStrings("native", dash.sessions[0].driverTypeSlice());
    try std.testing.expectEqual(session_mod.Session.Status.stopped, dash.sessions[0].status);
    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
}

test "Dashboard onBreakpoint set adds breakpoint" {
    var dash = Dashboard.init();
    const bp = types.BreakpointInfo{
        .id = 1,
        .verified = true,
        .file = "/tmp/test.c",
        .line = 42,
    };
    dash.onBreakpoint("set", bp);

    try std.testing.expectEqual(@as(usize, 1), dash.bp_count);
    try std.testing.expectEqual(@as(u32, 1), dash.breakpoints[0].id);
    try std.testing.expectEqualStrings("/tmp/test.c", dash.breakpoints[0].fileSlice());
    try std.testing.expectEqual(@as(u32, 42), dash.breakpoints[0].line);
}

test "Dashboard onBreakpoint remove removes breakpoint" {
    var dash = Dashboard.init();
    const bp1 = types.BreakpointInfo{ .id = 1, .verified = true, .file = "a.c", .line = 10 };
    const bp2 = types.BreakpointInfo{ .id = 2, .verified = true, .file = "b.c", .line = 20 };
    dash.onBreakpoint("set", bp1);
    dash.onBreakpoint("set", bp2);
    try std.testing.expectEqual(@as(usize, 2), dash.bp_count);

    dash.onBreakpoint("remove", bp1);
    try std.testing.expectEqual(@as(usize, 1), dash.bp_count);
    try std.testing.expectEqual(@as(u32, 2), dash.breakpoints[0].id);
}

test "Dashboard onRun updates session status and last_stop" {
    var dash = Dashboard.init();
    dash.onLaunch("session-1", "/tmp/test", "native");

    const state = types.StopState{
        .stop_reason = .exit,
        .exit_code = 0,
    };
    dash.onRun("session-1", "continue", state);

    try std.testing.expectEqual(session_mod.Session.Status.terminated, dash.sessions[0].status);
    try std.testing.expect(dash.last_stop != null);
    try std.testing.expectEqualStrings("exit", dash.last_stop.?.reason[0..dash.last_stop.?.reason_len]);
    try std.testing.expectEqual(@as(i32, 0), dash.last_stop.?.exit_code.?);
}

test "Dashboard onStop removes session" {
    var dash = Dashboard.init();
    dash.onLaunch("session-1", "/tmp/test", "native");
    try std.testing.expectEqual(@as(usize, 1), dash.session_count);

    dash.onStop("session-1");
    try std.testing.expectEqual(@as(usize, 0), dash.session_count);
}

test "Dashboard onInspect logs activity" {
    var dash = Dashboard.init();
    dash.onInspect("session-1", "a + b", "42");

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_inspect", entry.toolNameSlice());
}

test "Dashboard onError logs error entry" {
    var dash = Dashboard.init();
    dash.onError("debug_launch", "file not found");

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    try std.testing.expect(dash.log.entries[0].is_error);
}

test "RingLog wraps around correctly" {
    var log: RingLog = .{};
    // Fill beyond capacity
    for (0..20) |i| {
        var entry: LogEntry = .{};
        var buf: [20]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "tool_{d}", .{i}) catch "tool";
        copyInto(&entry.tool_name, &entry.tool_name_len, name);
        log.push(entry);
    }
    try std.testing.expectEqual(@as(usize, LOG_SIZE), log.count);

    // Oldest entry should be tool_4 (20 - 16 = 4)
    var it = log.iter();
    const first = it.next().?;
    try std.testing.expectEqualStrings("tool_4", first.toolNameSlice());
}

test "Dashboard render does not crash with empty state" {
    var dash = Dashboard.init();
    // enabled is false in test mode, so this is a no-op
    dash.render();
    try std.testing.expectEqual(@as(usize, 0), dash.rendered_lines);
}

test "Dashboard full lifecycle" {
    var dash = Dashboard.init();

    dash.onLaunch("session-1", "/tmp/debug_test", "native");
    dash.onBreakpoint("set", .{ .id = 1, .verified = true, .file = "/tmp/debug_test.c", .line = 4 });
    dash.onRun("session-1", "continue", .{ .stop_reason = .exit, .exit_code = 0 });
    dash.onInspect("session-1", "a + b", "");
    dash.onStop("session-1");

    try std.testing.expectEqual(@as(usize, 0), dash.session_count);
    try std.testing.expectEqual(@as(usize, 5), dash.log.count);
    try std.testing.expect(dash.last_stop != null);
}

test "Dashboard onInstructionBreakpoint logs activity" {
    var dash = Dashboard.init();
    dash.onInstructionBreakpoint("session-1", "0x400080", 2);

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_insn_bp", entry.toolNameSlice());
}

test "Dashboard onStepInTargets logs activity" {
    var dash = Dashboard.init();
    dash.onStepInTargets("session-1", 3, 5);

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_step_targets", entry.toolNameSlice());
}

test "Dashboard onBreakpointLocations logs activity" {
    var dash = Dashboard.init();
    dash.onBreakpointLocations("session-1", "main.c", 42, 3);

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_bp_locations", entry.toolNameSlice());
}

test "Dashboard onCancel logs activity" {
    var dash = Dashboard.init();
    dash.onCancel("session-1");

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_cancel", entry.toolNameSlice());
    try std.testing.expectEqualStrings("request cancelled", entry.summarySlice());
}

test "Dashboard onTerminateThreads logs activity" {
    var dash = Dashboard.init();
    dash.onTerminateThreads("session-1", 3);

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_term_threads", entry.toolNameSlice());
}

test "Dashboard onRestart logs activity" {
    var dash = Dashboard.init();
    dash.onRestart("session-1");

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_restart", entry.toolNameSlice());
}

test "Dashboard onLoadedSources logs activity" {
    var dash = Dashboard.init();
    dash.onLoadedSources("session-1", 12);

    try std.testing.expectEqual(@as(usize, 1), dash.log.count);
    const entry = &dash.log.entries[0];
    try std.testing.expectEqualStrings("debug_loaded_src", entry.toolNameSlice());
}
