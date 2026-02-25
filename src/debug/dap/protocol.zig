const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("../types.zig");

// ── DAP Base Types ──────────────────────────────────────────────────────

pub const MessageType = enum {
    request,
    response,
    event,
};

pub const DapRequest = struct {
    seq: i64,
    command: []const u8,
    arguments: ?json.Value = null,

    pub fn serialize(self: *const DapRequest, allocator: std.mem.Allocator) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        try s.beginObject();
        try s.objectField("seq");
        try s.write(self.seq);
        try s.objectField("type");
        try s.write("request");
        try s.objectField("command");
        try s.write(self.command);
        if (self.arguments) |args| {
            try s.objectField("arguments");
            try s.write(args);
        }
        try s.endObject();

        return try aw.toOwnedSlice();
    }
};

pub const DapResponse = struct {
    seq: i64,
    request_seq: i64,
    command: []const u8,
    success: bool,
    message: ?[]const u8 = null,
    body: ?json.Value = null,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !DapResponse {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const obj = parsed.value.object;

        const type_val = obj.get("type") orelse return error.InvalidResponse;
        if (type_val != .string) return error.InvalidResponse;
        if (!std.mem.eql(u8, type_val.string, "response")) return error.NotAResponse;

        const seq = if (obj.get("seq")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;

        const request_seq = if (obj.get("request_seq")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;

        const command_val = obj.get("command") orelse return error.InvalidResponse;
        if (command_val != .string) return error.InvalidResponse;
        const command = try allocator.dupe(u8, command_val.string);

        const success = if (obj.get("success")) |v| v == .bool and v.bool else false;

        const message = if (obj.get("message")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        return .{
            .seq = seq,
            .request_seq = request_seq,
            .command = command,
            .success = success,
            .message = message,
        };
    }

    pub fn deinit(self: *const DapResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.message) |m| allocator.free(m);
    }
};

pub const DapEvent = struct {
    seq: i64,
    event: []const u8,
    body: ?json.Value = null,

    // Parsed fields from common events
    stop_reason: ?[]const u8 = null,
    thread_id: ?i64 = null,
    exit_code: ?i64 = null,
    hit_breakpoint_ids: []const u32 = &.{},

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !DapEvent {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidEvent;
        const obj = parsed.value.object;

        const type_val = obj.get("type") orelse return error.InvalidEvent;
        if (type_val != .string) return error.InvalidEvent;
        if (!std.mem.eql(u8, type_val.string, "event")) return error.NotAnEvent;

        const seq = if (obj.get("seq")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;

        const event_val = obj.get("event") orelse return error.InvalidEvent;
        if (event_val != .string) return error.InvalidEvent;
        const event = try allocator.dupe(u8, event_val.string);

        var result: DapEvent = .{
            .seq = seq,
            .event = event,
        };

        // Parse body for common events
        if (obj.get("body")) |body| {
            if (body == .object) {
                const body_obj = body.object;
                if (body_obj.get("reason")) |r| {
                    if (r == .string) {
                        result.stop_reason = try allocator.dupe(u8, r.string);
                    }
                }
                if (body_obj.get("threadId")) |t| {
                    if (t == .integer) result.thread_id = t.integer;
                }
                if (body_obj.get("exitCode")) |e| {
                    if (e == .integer) result.exit_code = e.integer;
                }
                // Parse hitBreakpointIds from stopped events
                if (body_obj.get("hitBreakpointIds")) |ids| {
                    if (ids == .array) {
                        var bp_ids = std.ArrayListUnmanaged(u32).empty;
                        errdefer bp_ids.deinit(allocator);
                        for (ids.array.items) |item| {
                            if (item == .integer) {
                                try bp_ids.append(allocator, @intCast(item.integer));
                            }
                        }
                        result.hit_breakpoint_ids = try bp_ids.toOwnedSlice(allocator);
                    }
                }
            }
        }

        return result;
    }

    pub fn deinit(self: *const DapEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event);
        if (self.stop_reason) |r| allocator.free(r);
        if (self.hit_breakpoint_ids.len > 0) allocator.free(self.hit_breakpoint_ids);
    }
};

// ── Request Builders ────────────────────────────────────────────────────

pub fn initializeRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    return initializeRequestParams(allocator, seq, "cog", false);
}

pub fn initializeRequestParams(allocator: std.mem.Allocator, seq: i64, adapter_id: []const u8, supports_start_debugging: bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("initialize");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("clientID");
    try s.write("cog-debug");
    try s.objectField("adapterID");
    try s.write(adapter_id);
    try s.objectField("clientName");
    try s.write("Cog Debug");
    try s.objectField("locale");
    try s.write("en-US");
    try s.objectField("pathFormat");
    try s.write("path");
    try s.objectField("linesStartAt1");
    try s.write(true);
    try s.objectField("columnsStartAt1");
    try s.write(true);
    try s.objectField("supportsRunInTerminalRequest");
    try s.write(false);
    try s.objectField("supportsStartDebuggingRequest");
    try s.write(supports_start_debugging);
    // Advertise client capabilities
    try s.objectField("supportsVariableType");
    try s.write(true);
    try s.objectField("supportsVariablePaging");
    try s.write(true);
    try s.objectField("supportsMemoryReferences");
    try s.write(true);
    try s.objectField("supportsProgressReporting");
    try s.write(true);
    try s.objectField("supportsInvalidatedEvent");
    try s.write(true);
    try s.objectField("supportsMemoryEvent");
    try s.write(true);
    try s.objectField("supportsANSIStyling");
    try s.write(true);
    try s.objectField("supportsArgsCanBeInterpretedByShell");
    try s.write(true);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn launchRequest(allocator: std.mem.Allocator, seq: i64, program: []const u8, args: []const []const u8, stop_on_entry: bool) ![]const u8 {
    return launchRequestEx(allocator, seq, program, args, stop_on_entry, null, null);
}

/// Build a launch request with optional extra arguments merged from JSON and optional cwd.
/// extra_args_json, when non-null, is parsed and each field is written into the arguments object.
pub fn launchRequestEx(allocator: std.mem.Allocator, seq: i64, program: []const u8, args: []const []const u8, stop_on_entry: bool, extra_args_json: ?[]const u8, cwd: ?[]const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("launch");
    try s.objectField("arguments");
    try s.beginObject();

    // Write extra fields from JSON first (e.g. type, sourceMaps, outFiles for JS).
    // Template variables: {cwd} is replaced with the actual working directory so
    // that outFiles globs point to the program's location at runtime.
    if (extra_args_json) |extra| {
        var effective_extra = extra;
        var extra_owned: ?[]u8 = null;
        defer if (extra_owned) |e| allocator.free(e);

        if (cwd) |d| {
            if (std.mem.indexOf(u8, extra, "{cwd}") != null) {
                const new_size = std.mem.replacementSize(u8, extra, "{cwd}", d);
                const buf = try allocator.alloc(u8, new_size);
                _ = std.mem.replace(u8, extra, "{cwd}", d, buf);
                extra_owned = buf;
                effective_extra = buf;
            }
        }

        const parsed = json.parseFromSlice(json.Value, allocator, effective_extra, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                var it = p.value.object.iterator();
                while (it.next()) |entry| {
                    try s.objectField(entry.key_ptr.*);
                    try s.write(entry.value_ptr.*);
                }
            }
        }
    }

    try s.objectField("program");
    try s.write(program);
    if (args.len > 0) {
        try s.objectField("args");
        try s.beginArray();
        for (args) |arg| try s.write(arg);
        try s.endArray();
    }
    try s.objectField("stopOnEntry");
    try s.write(stop_on_entry);
    // Use internalConsole to prevent adapters from spawning a terminal
    // (integratedTerminal is the default and causes SIGTTIN when running headless)
    try s.objectField("console");
    try s.write("internalConsole");
    if (cwd) |d| {
        try s.objectField("cwd");
        try s.write(d);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub const BreakpointOption = struct {
    line: u32,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

pub fn setBreakpointsRequest(allocator: std.mem.Allocator, seq: i64, source_path: []const u8, lines: []const u32) ![]const u8 {
    return setBreakpointsRequestEx(allocator, seq, source_path, lines, null);
}

pub fn setBreakpointsRequestEx(allocator: std.mem.Allocator, seq: i64, source_path: []const u8, lines: []const u32, options: ?[]const BreakpointOption) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("source");
    try s.beginObject();
    try s.objectField("path");
    try s.write(source_path);
    try s.endObject();
    try s.objectField("breakpoints");
    try s.beginArray();
    if (options) |opts| {
        for (opts) |opt| {
            try s.beginObject();
            try s.objectField("line");
            try s.write(opt.line);
            if (opt.condition) |c| {
                try s.objectField("condition");
                try s.write(c);
            }
            if (opt.hit_condition) |hc| {
                try s.objectField("hitCondition");
                try s.write(hc);
            }
            if (opt.log_message) |lm| {
                try s.objectField("logMessage");
                try s.write(lm);
            }
            try s.endObject();
        }
    } else {
        for (lines) |line| {
            try s.beginObject();
            try s.objectField("line");
            try s.write(line);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub const SteppingOptions = struct {
    granularity: ?types.SteppingGranularity = null,
    single_thread: ?bool = null,
};

pub fn continueRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return continueRequestEx(allocator, seq, thread_id, null);
}

pub fn continueRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, single_thread: ?bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("continue");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    if (single_thread) |st| {
        try s.objectField("singleThread");
        try s.write(st);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn stepInRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return stepInRequestEx(allocator, seq, thread_id, .{});
}

pub fn stepInRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, opts: SteppingOptions) ![]const u8 {
    return steppingCommand(allocator, seq, "stepIn", thread_id, opts);
}

pub fn stepInRequestWithTarget(allocator: std.mem.Allocator, seq: i64, thread_id: i64, opts: SteppingOptions, target_id: u32) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("stepIn");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    try s.objectField("targetId");
    try s.write(target_id);
    if (opts.granularity) |g| {
        try s.objectField("granularity");
        try s.write(@tagName(g));
    }
    if (opts.single_thread) |st| {
        try s.objectField("singleThread");
        try s.write(st);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn nextRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return nextRequestEx(allocator, seq, thread_id, .{});
}

pub fn nextRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, opts: SteppingOptions) ![]const u8 {
    return steppingCommand(allocator, seq, "next", thread_id, opts);
}

pub fn stepOutRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return stepOutRequestEx(allocator, seq, thread_id, .{});
}

pub fn stepOutRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, opts: SteppingOptions) ![]const u8 {
    return steppingCommand(allocator, seq, "stepOut", thread_id, opts);
}

pub fn stackTraceRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64, start_frame: i64, levels: i64) ![]const u8 {
    return stackTraceRequestEx(allocator, seq, thread_id, start_frame, levels, null);
}

pub fn stackTraceRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, start_frame: i64, levels: i64, format: ?types.StackFrameFormat) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("stackTrace");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    try s.objectField("startFrame");
    try s.write(start_frame);
    try s.objectField("levels");
    try s.write(levels);
    if (format) |fmt| {
        try s.objectField("format");
        try writeStackFrameFormat(&s, fmt);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub const VariablesRequestOptions = struct {
    filter: ?types.VariableFilter = null,
    start: ?i64 = null,
    count: ?i64 = null,
    format: ?types.ValueFormat = null,
};

pub fn variablesRequest(allocator: std.mem.Allocator, seq: i64, variables_ref: i64) ![]const u8 {
    return variablesRequestEx(allocator, seq, variables_ref, .{});
}

pub fn variablesRequestEx(allocator: std.mem.Allocator, seq: i64, variables_ref: i64, opts: VariablesRequestOptions) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("variables");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("variablesReference");
    try s.write(variables_ref);
    if (opts.filter) |f| {
        try s.objectField("filter");
        try s.write(@tagName(f));
    }
    if (opts.start) |st| {
        try s.objectField("start");
        try s.write(st);
    }
    if (opts.count) |c| {
        try s.objectField("count");
        try s.write(c);
    }
    if (opts.format) |fmt| {
        try s.objectField("format");
        try writeValueFormat(&s, fmt);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn evaluateRequest(allocator: std.mem.Allocator, seq: i64, expression: []const u8, frame_id: ?i64) ![]const u8 {
    return evaluateRequestEx(allocator, seq, expression, frame_id, null, null, null, null);
}

pub fn evaluateRequestEx(allocator: std.mem.Allocator, seq: i64, expression: []const u8, frame_id: ?i64, context: ?types.EvaluateContext, format: ?types.ValueFormat, line: ?i64, column: ?i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("evaluate");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("expression");
    try s.write(expression);
    if (context) |ctx| {
        try s.objectField("context");
        try s.write(@tagName(ctx));
    }
    if (frame_id) |fid| {
        try s.objectField("frameId");
        try s.write(fid);
    }
    if (format) |f| {
        try s.objectField("format");
        try f.jsonStringify(&s);
    }
    if (line) |l| {
        try s.objectField("line");
        try s.write(l);
    }
    if (column) |c| {
        try s.objectField("column");
        try s.write(c);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn pauseRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "pause", thread_id);
}

pub fn threadsRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("threads");
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn readMemoryRequest(allocator: std.mem.Allocator, seq: i64, memory_ref: []const u8, offset: i64, count: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("readMemory");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("memoryReference");
    try s.write(memory_ref);
    try s.objectField("offset");
    try s.write(offset);
    try s.objectField("count");
    try s.write(count);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn writeMemoryRequest(allocator: std.mem.Allocator, seq: i64, memory_ref: []const u8, offset: i64, data_b64: []const u8, allow_partial: ?bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("writeMemory");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("memoryReference");
    try s.write(memory_ref);
    try s.objectField("offset");
    try s.write(offset);
    try s.objectField("data");
    try s.write(data_b64);
    if (allow_partial) |ap| {
        try s.objectField("allowPartial");
        try s.write(ap);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub const DisassembleOptions = struct {
    instruction_offset: ?i64 = null,
    resolve_symbols: ?bool = null,
    offset: ?i64 = null,
};

pub fn disassembleRequest(allocator: std.mem.Allocator, seq: i64, memory_ref: []const u8, instruction_count: i64) ![]const u8 {
    return disassembleRequestEx(allocator, seq, memory_ref, instruction_count, .{});
}

pub fn disassembleRequestEx(allocator: std.mem.Allocator, seq: i64, memory_ref: []const u8, instruction_count: i64, opts: DisassembleOptions) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("disassemble");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("memoryReference");
    try s.write(memory_ref);
    if (opts.offset) |off| {
        try s.objectField("offset");
        try s.write(off);
    }
    if (opts.instruction_offset) |offset| {
        try s.objectField("instructionOffset");
        try s.write(offset);
    }
    try s.objectField("instructionCount");
    try s.write(instruction_count);
    if (opts.resolve_symbols) |rs| {
        try s.objectField("resolveSymbols");
        try s.write(rs);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn attachRequest(allocator: std.mem.Allocator, seq: i64, pid: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("attach");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("processId");
    try s.write(pid);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn setFunctionBreakpointsRequest(allocator: std.mem.Allocator, seq: i64, names: []const []const u8, conditions: []const ?[]const u8, hit_conditions: []const ?[]const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setFunctionBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("breakpoints");
    try s.beginArray();
    for (names, 0..) |name, i| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(name);
        if (i < conditions.len) {
            if (conditions[i]) |cond| {
                try s.objectField("condition");
                try s.write(cond);
            }
        }
        if (i < hit_conditions.len) {
            if (hit_conditions[i]) |hc| {
                try s.objectField("hitCondition");
                try s.write(hc);
            }
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub const ExceptionFilterOption = struct {
    filter_id: []const u8,
    condition: ?[]const u8 = null,
};

pub fn setExceptionBreakpointsRequestEx(allocator: std.mem.Allocator, seq: i64, filters: []const []const u8, filter_options: ?[]const ExceptionFilterOption) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setExceptionBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("filters");
    try s.beginArray();
    for (filters) |f| {
        try s.write(f);
    }
    try s.endArray();
    if (filter_options) |opts| {
        if (opts.len > 0) {
            try s.objectField("filterOptions");
            try s.beginArray();
            for (opts) |opt| {
                try s.beginObject();
                try s.objectField("filterId");
                try s.write(opt.filter_id);
                if (opt.condition) |c| {
                    try s.objectField("condition");
                    try s.write(c);
                }
                try s.endObject();
            }
            try s.endArray();
        }
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn setExceptionBreakpointsRequest(allocator: std.mem.Allocator, seq: i64, filters: []const []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setExceptionBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("filters");
    try s.beginArray();
    for (filters) |f| {
        try s.write(f);
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn setVariableRequest(allocator: std.mem.Allocator, seq: i64, variables_ref: i64, name: []const u8, value: []const u8, format: ?types.ValueFormat) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setVariable");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("variablesReference");
    try s.write(variables_ref);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("value");
    try s.write(value);
    if (format) |f| {
        try s.objectField("format");
        try f.jsonStringify(&s);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn gotoTargetsRequest(allocator: std.mem.Allocator, seq: i64, source_path: []const u8, line: i64, column: ?i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("gotoTargets");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("source");
    try s.beginObject();
    try s.objectField("path");
    try s.write(source_path);
    try s.endObject();
    try s.objectField("line");
    try s.write(line);
    if (column) |col| {
        try s.objectField("column");
        try s.write(col);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn gotoRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64, target_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("goto");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    try s.objectField("targetId");
    try s.write(target_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn configurationDoneRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("configurationDone");
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn disconnectRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    return disconnectRequestEx(allocator, seq, true, false, null);
}

pub fn disconnectRequestEx(allocator: std.mem.Allocator, seq: i64, terminate_debuggee: bool, suspend_debuggee: bool, restart: ?bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("disconnect");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("terminateDebuggee");
    try s.write(terminate_debuggee);
    if (suspend_debuggee) {
        try s.objectField("suspendDebuggee");
        try s.write(true);
    }
    if (restart) |r| {
        try s.objectField("restart");
        try s.write(r);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn scopesRequest(allocator: std.mem.Allocator, seq: i64, frame_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("scopes");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("frameId");
    try s.write(frame_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

fn threadCommand(allocator: std.mem.Allocator, seq: i64, command: []const u8, thread_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write(command);
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

fn steppingCommand(allocator: std.mem.Allocator, seq: i64, command: []const u8, thread_id: i64, opts: SteppingOptions) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write(command);
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    if (opts.granularity) |g| {
        try s.objectField("granularity");
        try s.write(@tagName(g));
    }
    if (opts.single_thread) |st| {
        try s.objectField("singleThread");
        try s.write(st);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

fn writeStackFrameFormat(s: *Stringify, fmt: types.StackFrameFormat) !void {
    try s.beginObject();
    if (fmt.parameters) |v| {
        try s.objectField("parameters");
        try s.write(v);
    }
    if (fmt.parameter_types) |v| {
        try s.objectField("parameterTypes");
        try s.write(v);
    }
    if (fmt.parameter_names) |v| {
        try s.objectField("parameterNames");
        try s.write(v);
    }
    if (fmt.parameter_values) |v| {
        try s.objectField("parameterValues");
        try s.write(v);
    }
    if (fmt.line) |v| {
        try s.objectField("line");
        try s.write(v);
    }
    if (fmt.module) |v| {
        try s.objectField("module");
        try s.write(v);
    }
    if (fmt.include_all) |v| {
        try s.objectField("includeAll");
        try s.write(v);
    }
    try s.endObject();
}

fn writeValueFormat(s: *Stringify, fmt: types.ValueFormat) !void {
    try s.beginObject();
    if (fmt.hex) |v| {
        try s.objectField("hex");
        try s.write(v);
    }
    try s.endObject();
}

pub fn dataBreakpointInfoRequest(allocator: std.mem.Allocator, seq: i64, name: []const u8, variables_ref: ?i64, frame_id: ?i64, bytes: ?i64, as_address: ?bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("dataBreakpointInfo");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    if (variables_ref) |vr| {
        try s.objectField("variablesReference");
        try s.write(vr);
    }
    if (frame_id) |fid| {
        try s.objectField("frameId");
        try s.write(fid);
    }
    if (bytes) |b| {
        try s.objectField("bytes");
        try s.write(b);
    }
    if (as_address) |a| {
        try s.objectField("asAddress");
        try s.write(a);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub const DataBreakpointSpec = struct {
    data_id: []const u8,
    access_type: []const u8,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
};

pub fn setDataBreakpointsRequest(allocator: std.mem.Allocator, seq: i64, breakpoints: []const DataBreakpointSpec) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setDataBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("breakpoints");
    try s.beginArray();
    for (breakpoints) |bp| {
        try s.beginObject();
        try s.objectField("dataId");
        try s.write(bp.data_id);
        try s.objectField("accessType");
        try s.write(bp.access_type);
        if (bp.condition) |cond| {
            try s.objectField("condition");
            try s.write(cond);
        }
        if (bp.hit_condition) |hc| {
            try s.objectField("hitCondition");
            try s.write(hc);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn exceptionInfoRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "exceptionInfo", thread_id);
}

pub fn terminateRequest(allocator: std.mem.Allocator, seq: i64, restart: ?bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("terminate");
    if (restart) |r| {
        try s.objectField("arguments");
        try s.beginObject();
        try s.objectField("restart");
        try s.write(r);
        try s.endObject();
    }
    try s.endObject();

    return try aw.toOwnedSlice();
}

// ── Phase 5 Protocol Builders ───────────────────────────────────────────

pub fn completionsRequest(allocator: std.mem.Allocator, seq: i64, text: []const u8, column: i64, frame_id: ?i64, line: ?i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("completions");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("text");
    try s.write(text);
    try s.objectField("column");
    try s.write(column);
    if (frame_id) |fid| {
        try s.objectField("frameId");
        try s.write(fid);
    }
    if (line) |l| {
        try s.objectField("line");
        try s.write(l);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn modulesRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    return modulesRequestEx(allocator, seq, 0, 100);
}

pub fn modulesRequestEx(allocator: std.mem.Allocator, seq: i64, start_module: i64, module_count: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("modules");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("startModule");
    try s.write(start_module);
    try s.objectField("moduleCount");
    try s.write(module_count);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn loadedSourcesRequest(allocator: std.mem.Allocator, seq: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("loadedSources");
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn sourceRequest(allocator: std.mem.Allocator, seq: i64, source_reference: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("source");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("sourceReference");
    try s.write(source_reference);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn setExpressionRequest(allocator: std.mem.Allocator, seq: i64, expression: []const u8, value: []const u8, frame_id: ?i64, format: ?types.ValueFormat) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setExpression");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("expression");
    try s.write(expression);
    try s.objectField("value");
    try s.write(value);
    if (frame_id) |fid| {
        try s.objectField("frameId");
        try s.write(fid);
    }
    if (format) |f| {
        try s.objectField("format");
        try f.jsonStringify(&s);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

// ── Phase 6 Protocol Builders ───────────────────────────────────────────

pub fn reverseContinueRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "reverseContinue", thread_id);
}

pub fn stepBackRequest(allocator: std.mem.Allocator, seq: i64, thread_id: i64) ![]const u8 {
    return threadCommand(allocator, seq, "stepBack", thread_id);
}

pub fn stepBackRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, single_thread: ?bool, granularity: ?types.SteppingGranularity) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("stepBack");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    if (single_thread) |st| {
        try s.objectField("singleThread");
        try s.write(st);
    }
    if (granularity) |g| {
        try s.objectField("granularity");
        try s.write(@tagName(g));
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn reverseContinueRequestEx(allocator: std.mem.Allocator, seq: i64, thread_id: i64, single_thread: ?bool) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("reverseContinue");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadId");
    try s.write(thread_id);
    if (single_thread) |st| {
        try s.objectField("singleThread");
        try s.write(st);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn restartFrameRequest(allocator: std.mem.Allocator, seq: i64, frame_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("restartFrame");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("frameId");
    try s.write(frame_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

// ── WP9 Protocol Builders ───────────────────────────────────────────────

pub fn setInstructionBreakpointsRequest(allocator: std.mem.Allocator, seq: i64, breakpoints: []const types.InstructionBreakpoint) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("setInstructionBreakpoints");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("breakpoints");
    try s.beginArray();
    for (breakpoints) |bp| {
        try s.beginObject();
        try s.objectField("instructionReference");
        try s.write(bp.instruction_reference);
        if (bp.offset) |o| {
            try s.objectField("offset");
            try s.write(o);
        }
        if (bp.condition) |c| {
            try s.objectField("condition");
            try s.write(c);
        }
        if (bp.hit_condition) |hc| {
            try s.objectField("hitCondition");
            try s.write(hc);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn stepInTargetsRequest(allocator: std.mem.Allocator, seq: i64, frame_id: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("stepInTargets");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("frameId");
    try s.write(frame_id);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn breakpointLocationsRequest(allocator: std.mem.Allocator, seq: i64, source_path: []const u8, line: i64, end_line: ?i64, column: ?i64, end_column: ?i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("breakpointLocations");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("source");
    try s.beginObject();
    try s.objectField("path");
    try s.write(source_path);
    try s.endObject();
    try s.objectField("line");
    try s.write(line);
    if (column) |col| {
        try s.objectField("column");
        try s.write(col);
    }
    if (end_line) |el| {
        try s.objectField("endLine");
        try s.write(el);
    }
    if (end_column) |ec| {
        try s.objectField("endColumn");
        try s.write(ec);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn cancelRequest(allocator: std.mem.Allocator, seq: i64, request_id: ?i64, progress_id: ?[]const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("cancel");
    try s.objectField("arguments");
    try s.beginObject();
    if (request_id) |rid| {
        try s.objectField("requestId");
        try s.write(rid);
    }
    if (progress_id) |pid| {
        try s.objectField("progressId");
        try s.write(pid);
    }
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn terminateThreadsRequest(allocator: std.mem.Allocator, seq: i64, thread_ids: []const i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("terminateThreads");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("threadIds");
    try s.beginArray();
    for (thread_ids) |tid| {
        try s.write(tid);
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn locationsRequest(allocator: std.mem.Allocator, seq: i64, location_reference: i64) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("locations");
    try s.objectField("arguments");
    try s.beginObject();
    try s.objectField("locationReference");
    try s.write(location_reference);
    try s.endObject();
    try s.endObject();

    return try aw.toOwnedSlice();
}

pub fn restartRequest(allocator: std.mem.Allocator, seq: i64, arguments: ?[]const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("type");
    try s.write("request");
    try s.objectField("command");
    try s.write("restart");
    if (arguments) |args| {
        try s.objectField("arguments");
        try aw.writer.writeAll(args);
    }
    try s.endObject();

    return try aw.toOwnedSlice();
}

/// Build a launch request with raw JSON arguments for child session handshake.
/// Used when connecting to a vscode-js-debug child session — the configuration
/// object comes from the startDebugging reverse request and must be forwarded as-is.
pub fn childLaunchRequest(allocator: std.mem.Allocator, seq: i64, config_json: []const u8) ![]const u8 {
    // Parse the config JSON so we can embed it as the arguments value
    const parsed = try json.parseFromSlice(json.Value, allocator, config_json, .{});
    defer parsed.deinit();

    const req = DapRequest{
        .seq = seq,
        .command = "launch",
        .arguments = parsed.value,
    };
    return try req.serialize(allocator);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "DapRequest serializes with correct seq and type" {
    const allocator = std.testing.allocator;
    const req = DapRequest{
        .seq = 1,
        .command = "initialize",
    };
    const data = try req.serialize(allocator);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(@as(i64, 1), obj.get("seq").?.integer);
    try std.testing.expectEqualStrings("request", obj.get("type").?.string);
    try std.testing.expectEqualStrings("initialize", obj.get("command").?.string);
}

test "DapResponse deserializes success response" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":1,"type":"response","request_seq":1,"command":"initialize","success":true}
    ;
    const resp = try DapResponse.parse(allocator, data);
    defer resp.deinit(allocator);

    try std.testing.expect(resp.success);
    try std.testing.expectEqualStrings("initialize", resp.command);
    try std.testing.expectEqual(@as(i64, 1), resp.request_seq);
}

test "DapResponse deserializes error response" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":2,"type":"response","request_seq":1,"command":"launch","success":false,"message":"Failed to launch"}
    ;
    const resp = try DapResponse.parse(allocator, data);
    defer resp.deinit(allocator);

    try std.testing.expect(!resp.success);
    try std.testing.expectEqualStrings("launch", resp.command);
    try std.testing.expectEqualStrings("Failed to launch", resp.message.?);
}

test "DapEvent deserializes stopped event with reason" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":5,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":1}}
    ;
    const evt = try DapEvent.parse(allocator, data);
    defer evt.deinit(allocator);

    try std.testing.expectEqualStrings("stopped", evt.event);
    try std.testing.expectEqualStrings("breakpoint", evt.stop_reason.?);
    try std.testing.expectEqual(@as(i64, 1), evt.thread_id.?);
}

test "DapEvent deserializes exited event with exit code" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":10,"type":"event","event":"exited","body":{"exitCode":0}}
    ;
    const evt = try DapEvent.parse(allocator, data);
    defer evt.deinit(allocator);

    try std.testing.expectEqualStrings("exited", evt.event);
    try std.testing.expectEqual(@as(i64, 0), evt.exit_code.?);
}

test "InitializeRequest has correct command and arguments" {
    const allocator = std.testing.allocator;
    const data = try initializeRequest(allocator, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("initialize", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    try std.testing.expectEqualStrings("cog-debug", args.get("clientID").?.string);
    try std.testing.expect(args.get("linesStartAt1").?.bool);
}

test "SetBreakpointsRequest serializes source and breakpoints" {
    const allocator = std.testing.allocator;
    const lines = [_]u32{ 10, 20 };
    const data = try setBreakpointsRequest(allocator, 3, "/test/file.py", &lines);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("setBreakpoints", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    try std.testing.expectEqualStrings("/test/file.py", args.get("source").?.object.get("path").?.string);
    const bps = args.get("breakpoints").?.array;
    try std.testing.expectEqual(@as(usize, 2), bps.items.len);
    try std.testing.expectEqual(@as(i64, 10), bps.items[0].object.get("line").?.integer);
}

test "ContinueRequest serializes with threadId" {
    const allocator = std.testing.allocator;
    const data = try continueRequest(allocator, 5, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("continue", obj.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("arguments").?.object.get("threadId").?.integer);
}

test "StepInRequest serializes with threadId" {
    const allocator = std.testing.allocator;
    const data = try stepInRequest(allocator, 6, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepIn", parsed.value.object.get("command").?.string);
}

test "StackTraceRequest serializes with startFrame and levels" {
    const allocator = std.testing.allocator;
    const data = try stackTraceRequest(allocator, 7, 1, 0, 5);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqual(@as(i64, 0), args.get("startFrame").?.integer);
    try std.testing.expectEqual(@as(i64, 5), args.get("levels").?.integer);
}

test "VariablesRequest serializes with variablesReference" {
    const allocator = std.testing.allocator;
    const data = try variablesRequest(allocator, 8, 42);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("arguments").?.object.get("variablesReference").?.integer);
}

test "EvaluateRequest serializes with expression and frameId" {
    const allocator = std.testing.allocator;
    const data = try evaluateRequest(allocator, 9, "len(items)", 3);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("len(items)", args.get("expression").?.string);
    try std.testing.expectEqual(@as(i64, 3), args.get("frameId").?.integer);
}

test "ThreadsRequest serializes without arguments" {
    const allocator = std.testing.allocator;
    const data = try threadsRequest(allocator, 10);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("threads", parsed.value.object.get("command").?.string);
}

test "AttachRequest serializes with processId" {
    const allocator = std.testing.allocator;
    const data = try attachRequest(allocator, 11, 12345);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("attach", parsed.value.object.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 12345), parsed.value.object.get("arguments").?.object.get("processId").?.integer);
}

test "SetFunctionBreakpointsRequest serializes with breakpoint names" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "main", "compute" };
    const conditions = [_]?[]const u8{ null, "x > 0" };
    const hit_conds = [_]?[]const u8{ null, null };
    const data = try setFunctionBreakpointsRequest(allocator, 12, &names, &conditions, &hit_conds);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("setFunctionBreakpoints", parsed.value.object.get("command").?.string);
    const bps = parsed.value.object.get("arguments").?.object.get("breakpoints").?.array;
    try std.testing.expectEqual(@as(usize, 2), bps.items.len);
    try std.testing.expectEqualStrings("main", bps.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("x > 0", bps.items[1].object.get("condition").?.string);
}

test "SetExceptionBreakpointsRequest serializes with filters" {
    const allocator = std.testing.allocator;
    const filters = [_][]const u8{ "uncaught", "raised" };
    const data = try setExceptionBreakpointsRequest(allocator, 13, &filters);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("setExceptionBreakpoints", parsed.value.object.get("command").?.string);
    const f = parsed.value.object.get("arguments").?.object.get("filters").?.array;
    try std.testing.expectEqual(@as(usize, 2), f.items.len);
    try std.testing.expectEqualStrings("uncaught", f.items[0].string);
}

test "ConfigurationDoneRequest serializes correctly" {
    const allocator = std.testing.allocator;
    const data = try configurationDoneRequest(allocator, 14);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("configurationDone", parsed.value.object.get("command").?.string);
}

test "GotoTargetsRequest serializes with source and line" {
    const allocator = std.testing.allocator;
    const data = try gotoTargetsRequest(allocator, 15, "/test/main.py", 25, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("gotoTargets", parsed.value.object.get("command").?.string);
    const args = parsed.value.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("/test/main.py", args.get("source").?.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 25), args.get("line").?.integer);
}

test "SetVariableRequest serializes with variablesReference, name, and value" {
    const allocator = std.testing.allocator;
    const data = try setVariableRequest(allocator, 16, 42, "x", "100", null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("setVariable", parsed.value.object.get("command").?.string);
    const args = parsed.value.object.get("arguments").?.object;
    try std.testing.expectEqual(@as(i64, 42), args.get("variablesReference").?.integer);
    try std.testing.expectEqualStrings("x", args.get("name").?.string);
    try std.testing.expectEqualStrings("100", args.get("value").?.string);
}

// ── WP9 Tests ───────────────────────────────────────────────────────────

test "InitializeRequest advertises client capabilities" {
    const allocator = std.testing.allocator;
    const data = try initializeRequest(allocator, 1);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expect(args.get("supportsVariableType").?.bool);
    try std.testing.expect(args.get("supportsVariablePaging").?.bool);
    try std.testing.expect(args.get("supportsMemoryReferences").?.bool);
    try std.testing.expect(args.get("supportsProgressReporting").?.bool);
    try std.testing.expect(args.get("supportsInvalidatedEvent").?.bool);
    try std.testing.expect(args.get("supportsMemoryEvent").?.bool);
    try std.testing.expect(!args.get("supportsStartDebuggingRequest").?.bool);
    try std.testing.expect(!args.get("supportsRunInTerminalRequest").?.bool);
    try std.testing.expect(args.get("supportsANSIStyling").?.bool);
}

test "ContinueRequestEx serializes with singleThread" {
    const allocator = std.testing.allocator;
    const data = try continueRequestEx(allocator, 5, 1, true);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("continue", parsed.value.object.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 1), args.get("threadId").?.integer);
    try std.testing.expect(args.get("singleThread").?.bool);
}

test "ContinueRequestEx omits singleThread when null" {
    const allocator = std.testing.allocator;
    const data = try continueRequestEx(allocator, 5, 1, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expect(args.get("singleThread") == null);
}

test "StepInRequestEx serializes with granularity and singleThread" {
    const allocator = std.testing.allocator;
    const data = try stepInRequestEx(allocator, 6, 1, .{
        .granularity = .instruction,
        .single_thread = true,
    });
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("stepIn", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("instruction", args.get("granularity").?.string);
    try std.testing.expect(args.get("singleThread").?.bool);
}

test "NextRequestEx serializes with granularity" {
    const allocator = std.testing.allocator;
    const data = try nextRequestEx(allocator, 7, 1, .{ .granularity = .line });
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("line", args.get("granularity").?.string);
}

test "StepOutRequestEx serializes with singleThread" {
    const allocator = std.testing.allocator;
    const data = try stepOutRequestEx(allocator, 8, 1, .{ .single_thread = false });
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("stepOut", parsed.value.object.get("command").?.string);
    try std.testing.expect(!args.get("singleThread").?.bool);
}

test "EvaluateRequestEx serializes with explicit context" {
    const allocator = std.testing.allocator;
    const data = try evaluateRequestEx(allocator, 9, "x.value", 3, .hover, null, null, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("hover", args.get("context").?.string);
    try std.testing.expectEqualStrings("x.value", args.get("expression").?.string);
}

test "EvaluateRequestEx omits context when null" {
    const allocator = std.testing.allocator;
    const data = try evaluateRequestEx(allocator, 9, "x + y", null, null, null, null, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expect(args.get("context") == null);
    try std.testing.expect(args.get("frameId") == null);
}

test "VariablesRequestEx serializes with filter, start, count, format" {
    const allocator = std.testing.allocator;
    const data = try variablesRequestEx(allocator, 10, 42, .{
        .filter = .indexed,
        .start = 0,
        .count = 10,
        .format = .{ .hex = true },
    });
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqual(@as(i64, 42), args.get("variablesReference").?.integer);
    try std.testing.expectEqualStrings("indexed", args.get("filter").?.string);
    try std.testing.expectEqual(@as(i64, 0), args.get("start").?.integer);
    try std.testing.expectEqual(@as(i64, 10), args.get("count").?.integer);
    const fmt = args.get("format").?.object;
    try std.testing.expect(fmt.get("hex").?.bool);
}

test "StackTraceRequestEx serializes with format" {
    const allocator = std.testing.allocator;
    const data = try stackTraceRequestEx(allocator, 11, 1, 0, 20, .{
        .parameters = true,
        .parameter_types = true,
        .module = true,
    });
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqual(@as(i64, 1), args.get("threadId").?.integer);
    const fmt = args.get("format").?.object;
    try std.testing.expect(fmt.get("parameters").?.bool);
    try std.testing.expect(fmt.get("parameterTypes").?.bool);
    try std.testing.expect(fmt.get("module").?.bool);
    try std.testing.expect(fmt.get("parameterNames") == null);
}

test "DisassembleRequestEx serializes with instructionOffset and resolveSymbols" {
    const allocator = std.testing.allocator;
    const data = try disassembleRequestEx(allocator, 12, "0x1000", 50, .{
        .instruction_offset = -10,
        .resolve_symbols = true,
    });
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("0x1000", args.get("memoryReference").?.string);
    try std.testing.expectEqual(@as(i64, -10), args.get("instructionOffset").?.integer);
    try std.testing.expectEqual(@as(i64, 50), args.get("instructionCount").?.integer);
    try std.testing.expect(args.get("resolveSymbols").?.bool);
}

test "ModulesRequestEx serializes with custom start and count" {
    const allocator = std.testing.allocator;
    const data = try modulesRequestEx(allocator, 13, 10, 50);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expectEqualStrings("modules", parsed.value.object.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 10), args.get("startModule").?.integer);
    try std.testing.expectEqual(@as(i64, 50), args.get("moduleCount").?.integer);
}

test "SetInstructionBreakpointsRequest serializes breakpoints" {
    const allocator = std.testing.allocator;
    const bps = [_]types.InstructionBreakpoint{
        .{ .instruction_reference = "0x1000", .offset = 4, .condition = "x > 0" },
        .{ .instruction_reference = "0x2000" },
    };
    const data = try setInstructionBreakpointsRequest(allocator, 14, &bps);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("setInstructionBreakpoints", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    const bp_arr = args.get("breakpoints").?.array;
    try std.testing.expectEqual(@as(usize, 2), bp_arr.items.len);
    try std.testing.expectEqualStrings("0x1000", bp_arr.items[0].object.get("instructionReference").?.string);
    try std.testing.expectEqual(@as(i64, 4), bp_arr.items[0].object.get("offset").?.integer);
    try std.testing.expectEqualStrings("x > 0", bp_arr.items[0].object.get("condition").?.string);
    try std.testing.expectEqualStrings("0x2000", bp_arr.items[1].object.get("instructionReference").?.string);
    try std.testing.expect(bp_arr.items[1].object.get("offset") == null);
}

test "StepInTargetsRequest serializes with frameId" {
    const allocator = std.testing.allocator;
    const data = try stepInTargetsRequest(allocator, 15, 5);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("stepInTargets", obj.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 5), obj.get("arguments").?.object.get("frameId").?.integer);
}

test "BreakpointLocationsRequest serializes with source, line, and endLine" {
    const allocator = std.testing.allocator;
    const data = try breakpointLocationsRequest(allocator, 16, "/src/main.zig", 10, 20, null, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("breakpointLocations", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    try std.testing.expectEqualStrings("/src/main.zig", args.get("source").?.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 10), args.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 20), args.get("endLine").?.integer);
}

test "BreakpointLocationsRequest omits endLine when null" {
    const allocator = std.testing.allocator;
    const data = try breakpointLocationsRequest(allocator, 16, "/src/main.zig", 10, null, null, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expect(args.get("endLine") == null);
}

test "CancelRequest serializes with requestId" {
    const allocator = std.testing.allocator;
    const data = try cancelRequest(allocator, 17, 42, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("cancel", obj.get("command").?.string);
    const args = obj.get("arguments").?.object;
    try std.testing.expectEqual(@as(i64, 42), args.get("requestId").?.integer);
    try std.testing.expect(args.get("progressId") == null);
}

test "CancelRequest serializes with progressId" {
    const allocator = std.testing.allocator;
    const data = try cancelRequest(allocator, 17, null, "progress-123");
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("arguments").?.object;

    try std.testing.expect(args.get("requestId") == null);
    try std.testing.expectEqualStrings("progress-123", args.get("progressId").?.string);
}

test "TerminateThreadsRequest serializes with threadIds" {
    const allocator = std.testing.allocator;
    const ids = [_]i64{ 1, 2, 3 };
    const data = try terminateThreadsRequest(allocator, 18, &ids);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("terminateThreads", obj.get("command").?.string);
    const tids = obj.get("arguments").?.object.get("threadIds").?.array;
    try std.testing.expectEqual(@as(usize, 3), tids.items.len);
    try std.testing.expectEqual(@as(i64, 1), tids.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), tids.items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), tids.items[2].integer);
}

test "LocationsRequest serializes with locationReference" {
    const allocator = std.testing.allocator;
    const data = try locationsRequest(allocator, 19, 42);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("locations", obj.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("arguments").?.object.get("locationReference").?.integer);
}

test "RestartRequest serializes without arguments" {
    const allocator = std.testing.allocator;
    const data = try restartRequest(allocator, 20, null);
    defer allocator.free(data);

    const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("restart", obj.get("command").?.string);
    try std.testing.expect(obj.get("arguments") == null);
}
