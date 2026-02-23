const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;

// ── Core Debug Types ────────────────────────────────────────────────────

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32 = 0,
    function: []const u8 = "",
};

pub const StackFrame = struct {
    id: u32,
    name: []const u8,
    source: []const u8,
    line: u32,
    column: u32 = 0,
    language: []const u8 = "",
    is_boundary: bool = false,
    address: u64 = 0,
    fp: u64 = 0,
    sp: u64 = 0,

    pub fn jsonStringify(self: *const StackFrame, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("source");
        try jw.write(self.source);
        try jw.objectField("line");
        try jw.write(self.line);
        try jw.objectField("column");
        try jw.write(self.column);
        try jw.endObject();
    }
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    @"type": []const u8 = "",
    children_count: u32 = 0,
    variables_reference: u32 = 0,
    named_variables: ?u32 = null,
    indexed_variables: ?u32 = null,
    evaluate_name: []const u8 = "",
    memory_reference: []const u8 = "",
    presentation_hint: ?VariablePresentationHint = null,

    pub fn jsonStringify(self: *const Variable, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("value");
        try jw.write(self.value);
        if (self.@"type".len > 0) {
            try jw.objectField("type");
            try jw.write(self.@"type");
        }
        try jw.objectField("variablesReference");
        try jw.write(self.variables_reference);
        if (self.named_variables) |nv| {
            try jw.objectField("namedVariables");
            try jw.write(nv);
        }
        if (self.indexed_variables) |iv| {
            try jw.objectField("indexedVariables");
            try jw.write(iv);
        }
        if (self.evaluate_name.len > 0) {
            try jw.objectField("evaluateName");
            try jw.write(self.evaluate_name);
        }
        if (self.memory_reference.len > 0) {
            try jw.objectField("memoryReference");
            try jw.write(self.memory_reference);
        }
        if (self.presentation_hint) |*ph| {
            try jw.objectField("presentationHint");
            try ph.jsonStringify(jw);
        }
        try jw.endObject();
    }
};

pub const StopReason = enum {
    breakpoint,
    step,
    exception,
    entry,
    pause,
    goto,
    function_breakpoint,
    data_breakpoint,
    instruction_breakpoint,
    exited,

    pub fn jsonStringify(self: *const StopReason, jw: anytype) !void {
        try jw.write(switch (self.*) {
            .function_breakpoint => "function breakpoint",
            .data_breakpoint => "data breakpoint",
            .instruction_breakpoint => "instruction breakpoint",
            else => @tagName(self.*),
        });
    }
};

pub const OutputEntry = struct {
    category: []const u8,
    text: []const u8,

    pub fn jsonStringify(self: *const OutputEntry, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("category");
        try jw.write(self.category);
        try jw.objectField("text");
        try jw.write(self.text);
        try jw.endObject();
    }
};

pub const ExceptionDetails = struct {
    message: []const u8 = "",
    type_name: []const u8 = "",
    stack_trace: []const u8 = "",

    pub fn jsonStringify(self: *const ExceptionDetails, jw: anytype) !void {
        try jw.beginObject();
        if (self.message.len > 0) {
            try jw.objectField("message");
            try jw.write(self.message);
        }
        if (self.type_name.len > 0) {
            try jw.objectField("typeName");
            try jw.write(self.type_name);
        }
        if (self.stack_trace.len > 0) {
            try jw.objectField("stackTrace");
            try jw.write(self.stack_trace);
        }
        try jw.endObject();
    }
};

pub const ExceptionInfo = struct {
    @"type": []const u8,
    message: []const u8,
    id: ?[]const u8 = null,
    break_mode: []const u8 = "unhandled",
    details: ?ExceptionDetails = null,

    pub fn jsonStringify(self: *const ExceptionInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("exceptionId");
        try jw.write(self.@"type");
        if (self.message.len > 0) {
            try jw.objectField("description");
            try jw.write(self.message);
        }
        try jw.objectField("breakMode");
        try jw.write(self.break_mode);
        if (self.details) |*d| {
            try jw.objectField("details");
            try d.jsonStringify(jw);
        }
        try jw.endObject();
    }
};

pub const RegisterInfo = struct {
    name: []const u8,
    value: u64,

    pub fn jsonStringify(self: *const RegisterInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("value");
        // Format as hex string for readability
        var buf: [18]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "0x{x}", .{self.value}) catch "0x0";
        try jw.write(hex);
        try jw.endObject();
    }
};

pub const Scope = struct {
    name: []const u8,
    variables_reference: u32 = 0,
    expensive: bool = false,

    pub fn jsonStringify(self: *const Scope, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("variablesReference");
        try jw.write(self.variables_reference);
        try jw.objectField("expensive");
        try jw.write(self.expensive);
        try jw.endObject();
    }
};

pub const DataBreakpointAccessType = enum {
    read,
    write,
    readWrite,

    pub fn parse(s: []const u8) ?DataBreakpointAccessType {
        if (std.mem.eql(u8, s, "read")) return .read;
        if (std.mem.eql(u8, s, "write")) return .write;
        if (std.mem.eql(u8, s, "readWrite")) return .readWrite;
        return null;
    }
};

pub const DataBreakpointInfo = struct {
    data_id: ?[]const u8 = null,
    description: []const u8 = "",
    access_types: []const DataBreakpointAccessType = &.{},
    can_persist: bool = false,

    pub fn jsonStringify(self: *const DataBreakpointInfo, jw: anytype) !void {
        try jw.beginObject();
        if (self.data_id) |id| {
            try jw.objectField("dataId");
            try jw.write(id);
        }
        try jw.objectField("description");
        try jw.write(self.description);
        if (self.access_types.len > 0) {
            try jw.objectField("accessTypes");
            try jw.beginArray();
            for (self.access_types) |at| {
                try jw.write(@tagName(at));
            }
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const CompletionItem = struct {
    label: []const u8,
    text: []const u8 = "",
    sort_text: []const u8 = "",
    item_type: []const u8 = "", // "method", "function", "variable", "field", etc.

    pub fn jsonStringify(self: *const CompletionItem, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("label");
        try jw.write(self.label);
        if (self.text.len > 0) {
            try jw.objectField("text");
            try jw.write(self.text);
        }
        if (self.item_type.len > 0) {
            try jw.objectField("type");
            try jw.write(self.item_type);
        }
        try jw.endObject();
    }
};

pub const Module = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8 = "",
    is_optimized: bool = false,
    symbol_status: []const u8 = "",

    pub fn jsonStringify(self: *const Module, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.path.len > 0) {
            try jw.objectField("path");
            try jw.write(self.path);
        }
        try jw.objectField("isOptimized");
        try jw.write(self.is_optimized);
        if (self.symbol_status.len > 0) {
            try jw.objectField("symbolStatus");
            try jw.write(self.symbol_status);
        }
        try jw.endObject();
    }
};

pub const Checksum = struct {
    algorithm: []const u8, // "MD5", "SHA1", "SHA256", "timestamp"
    checksum: []const u8,

    pub fn jsonStringify(self: *const Checksum, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("algorithm");
        try jw.write(self.algorithm);
        try jw.objectField("checksum");
        try jw.write(self.checksum);
        try jw.endObject();
    }
};

pub const LoadedSource = struct {
    name: []const u8,
    path: []const u8 = "",
    source_reference: u32 = 0,
    checksums: []const Checksum = &.{},

    pub fn jsonStringify(self: *const LoadedSource, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.path.len > 0) {
            try jw.objectField("path");
            try jw.write(self.path);
        }
        if (self.source_reference > 0) {
            try jw.objectField("sourceReference");
            try jw.write(self.source_reference);
        }
        if (self.checksums.len > 0) {
            try jw.objectField("checksums");
            try jw.beginArray();
            for (self.checksums) |*cs| {
                try cs.jsonStringify(jw);
            }
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const DebugCapabilities = struct {
    supports_conditional_breakpoints: bool = false,
    supports_hit_conditional_breakpoints: bool = false,
    supports_log_points: bool = false,
    supports_function_breakpoints: bool = false,
    supports_data_breakpoints: bool = false,
    supports_step_back: bool = false,
    supports_restart_frame: bool = false,
    supports_goto_targets: bool = false,
    supports_completions: bool = false,
    supports_modules: bool = false,
    supports_set_variable: bool = false,
    supports_set_expression: bool = false,
    supports_terminate: bool = false,
    supports_read_memory: bool = false,
    supports_write_memory: bool = false,
    supports_disassemble: bool = false,
    supports_instruction_breakpoints: bool = false,
    supports_stepping_granularity: bool = false,
    supports_cancel_request: bool = false,
    supports_terminate_threads: bool = false,
    supports_breakpoint_locations: bool = false,
    supports_step_in_targets: bool = false,
    supports_evaluate_for_hovers: bool = false,
    supports_value_formatting: bool = false,
    supports_loaded_sources: bool = false,
    supports_restart_request: bool = false,
    supports_single_thread_execution_requests: bool = false,
    supports_exception_options: bool = false,
    supports_exception_filter_options: bool = false,
    supports_exception_info_request: bool = false,
    support_terminate_debuggee: bool = false,
    support_suspend_debuggee: bool = false,
    supports_delayed_stack_trace_loading: bool = false,
    supports_clipboard_context: bool = false,
    supports_configuration_done_request: bool = false,
    supports_data_breakpoint_bytes: bool = false,
    supports_ansi_styling: bool = false,
    supports_locations_request: bool = false,
    supports_breakpoint_modes: bool = false,

    fn snakeToCamelCase(comptime snake: []const u8) []const u8 {
        const len = comptime len: {
            var count: usize = 0;
            for (snake) |c| {
                if (c != '_') count += 1;
            }
            break :len count;
        };
        const buf = comptime buf: {
            var result: [len]u8 = undefined;
            var j: usize = 0;
            var capitalize_next = false;
            for (snake) |c| {
                if (c == '_') {
                    capitalize_next = true;
                } else if (capitalize_next) {
                    result[j] = c - 32; // uppercase
                    j += 1;
                    capitalize_next = false;
                } else {
                    result[j] = c;
                    j += 1;
                }
            }
            break :buf result;
        };
        return &buf;
    }

    fn dapCapabilityName(comptime field_name: []const u8) []const u8 {
        // Map specific fields to their DAP-spec names (with "Request"/"Options" suffix)
        const overrides = .{
            .{ "supports_read_memory", "supportsReadMemoryRequest" },
            .{ "supports_write_memory", "supportsWriteMemoryRequest" },
            .{ "supports_disassemble", "supportsDisassembleRequest" },
            .{ "supports_modules", "supportsModulesRequest" },
            .{ "supports_loaded_sources", "supportsLoadedSourcesRequest" },
            .{ "supports_completions", "supportsCompletionsRequest" },
            .{ "supports_terminate", "supportsTerminateRequest" },
            .{ "supports_cancel_request", "supportsCancelRequest" },
            .{ "supports_terminate_threads", "supportsTerminateThreadsRequest" },
            .{ "supports_breakpoint_locations", "supportsBreakpointLocationsRequest" },
            .{ "supports_step_in_targets", "supportsStepInTargetsRequest" },
            .{ "supports_restart_request", "supportsRestartRequest" },
            .{ "supports_configuration_done_request", "supportsConfigurationDoneRequest" },
            .{ "supports_value_formatting", "supportsValueFormattingOptions" },
        };
        inline for (overrides) |entry| {
            if (std.mem.eql(u8, field_name, entry[0])) return entry[1];
        }
        return snakeToCamelCase(field_name);
    }

    pub fn jsonStringify(self: *const DebugCapabilities, jw: anytype) !void {
        @setEvalBranchQuota(10000);
        try jw.beginObject();
        inline for (std.meta.fields(DebugCapabilities)) |field| {
            if (@field(self, field.name)) {
                try jw.objectField(comptime dapCapabilityName(field.name));
                try jw.write(true);
            }
        }
        try jw.endObject();
    }
};

pub const StopState = struct {
    stop_reason: StopReason,
    location: ?SourceLocation = null,
    stack_trace: []const StackFrame = &.{},
    locals: []const Variable = &.{},
    exception: ?ExceptionInfo = null,
    exit_code: ?i32 = null,
    /// Internal: signals the engine to transparently resume (not serialized)
    should_resume: bool = false,
    /// Log point messages collected during transparent resumes (serialized)
    log_messages: []const []const u8 = &.{},
    /// Output captured from the debuggee (stdout/stderr via DAP output events)
    output: []const OutputEntry = &.{},
    /// IDs of breakpoints that were hit (from DAP stopped event hitBreakpointIds)
    hit_breakpoint_ids: []const u32 = &.{},

    pub fn jsonStringify(self: *const StopState, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("stop_reason");
        try jw.write(@tagName(self.stop_reason));
        if (self.location) |loc| {
            try jw.objectField("location");
            try jw.beginObject();
            try jw.objectField("file");
            try jw.write(loc.file);
            try jw.objectField("line");
            try jw.write(loc.line);
            try jw.objectField("function");
            try jw.write(loc.function);
            try jw.endObject();
        }
        if (self.stack_trace.len > 0) {
            try jw.objectField("stack_trace");
            try jw.beginArray();
            for (self.stack_trace) |*frame| {
                try frame.jsonStringify(jw);
            }
            try jw.endArray();
        }
        if (self.locals.len > 0) {
            try jw.objectField("locals");
            try jw.beginArray();
            for (self.locals) |*v| {
                try v.jsonStringify(jw);
            }
            try jw.endArray();
        }
        if (self.exception) |*exc| {
            try jw.objectField("exception");
            try exc.jsonStringify(jw);
        }
        if (self.exit_code) |code| {
            try jw.objectField("exit_code");
            try jw.write(code);
        }
        if (self.log_messages.len > 0) {
            try jw.objectField("log_messages");
            try jw.beginArray();
            for (self.log_messages) |msg| {
                try jw.write(msg);
            }
            try jw.endArray();
        }
        if (self.output.len > 0) {
            try jw.objectField("output");
            try jw.beginArray();
            for (self.output) |*entry| {
                try entry.jsonStringify(jw);
            }
            try jw.endArray();
        }
        if (self.hit_breakpoint_ids.len > 0) {
            try jw.objectField("hit_breakpoint_ids");
            try jw.beginArray();
            for (self.hit_breakpoint_ids) |bp_id| {
                try jw.write(bp_id);
            }
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const RunAction = enum {
    @"continue",
    step_into,
    step_over,
    step_out,
    restart,
    pause,
    reverse_continue,
    step_back,

    pub fn parse(s: []const u8) ?RunAction {
        const map = .{
            .{ "continue", .@"continue" },
            .{ "step_into", .step_into },
            .{ "step_over", .step_over },
            .{ "step_out", .step_out },
            .{ "restart", .restart },
            .{ "pause", .pause },
            .{ "reverse_continue", .reverse_continue },
            .{ "step_back", .step_back },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const BreakpointAction = enum {
    set,
    remove,
    list,
};

pub const BreakpointInfo = struct {
    id: u32,
    verified: bool,
    file: []const u8,
    line: u32,
    actual_line: ?u32 = null,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,

    pub fn jsonStringify(self: *const BreakpointInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("verified");
        try jw.write(self.verified);
        try jw.objectField("source");
        try jw.beginObject();
        try jw.objectField("path");
        try jw.write(self.file);
        try jw.endObject();
        if (self.actual_line) |al| {
            try jw.objectField("line");
            try jw.write(al);
        } else {
            try jw.objectField("line");
            try jw.write(self.line);
        }
        if (self.condition) |c| {
            try jw.objectField("condition");
            try jw.write(c);
        }
        try jw.endObject();
    }
};

pub const LaunchConfig = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
    env: ?std.json.ObjectMap = null,
    cwd: ?[]const u8 = null,
    language: ?[]const u8 = null,
    stop_on_entry: bool = false,

    pub fn parseFromJson(allocator: std.mem.Allocator, value: std.json.Value) !LaunchConfig {
        if (value != .object) return error.InvalidParams;
        const obj = value.object;

        const program_val = obj.get("program") orelse return error.InvalidParams;
        if (program_val != .string) return error.InvalidParams;
        const program = try allocator.dupe(u8, program_val.string);
        errdefer allocator.free(program);

        var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (args_list.items) |a| allocator.free(a);
            args_list.deinit(allocator);
        }
        if (obj.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |item| {
                    if (item == .string) {
                        try args_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }

        const stop_on_entry = if (obj.get("stop_on_entry")) |v| v == .bool and v.bool else false;

        const language = if (obj.get("language")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        const cwd = if (obj.get("cwd")) |v| blk: {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
            break :blk null;
        } else null;

        return .{
            .program = program,
            .args = try args_list.toOwnedSlice(allocator),
            .cwd = cwd,
            .language = language,
            .stop_on_entry = stop_on_entry,
        };
    }

    pub fn deinit(self: *const LaunchConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.program);
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
        if (self.language) |l| allocator.free(l);
        if (self.cwd) |c| allocator.free(c);
    }
};

pub const ThreadInfo = struct {
    id: u32,
    name: []const u8,
    is_stopped: bool = false,

    pub fn jsonStringify(self: *const ThreadInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.endObject();
    }
};

pub const DisassembledInstruction = struct {
    address: []const u8,
    instruction: []const u8,
    instruction_bytes: []const u8 = "",

    pub fn jsonStringify(self: *const DisassembledInstruction, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("address");
        try jw.write(self.address);
        try jw.objectField("instruction");
        try jw.write(self.instruction);
        if (self.instruction_bytes.len > 0) {
            try jw.objectField("instructionBytes");
            try jw.write(self.instruction_bytes);
        }
        try jw.endObject();
    }
};

pub const MemoryResult = struct {
    data: []const u8,
    address: []const u8,
    size: u64,

    pub fn jsonStringify(self: *const MemoryResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("data");
        try jw.write(self.data);
        try jw.objectField("address");
        try jw.write(self.address);
        try jw.objectField("size");
        try jw.write(self.size);
        try jw.endObject();
    }
};

pub const RunOptions = struct {
    granularity: ?SteppingGranularity = null,
    target_id: ?u32 = null,
    thread_id: ?u32 = null,
};

pub const InspectRequest = struct {
    expression: ?[]const u8 = null,
    variable_ref: ?u32 = null,
    frame_id: ?u32 = null,
    scope: ?[]const u8 = null,
    context: ?EvaluateContext = null,
};

pub const InspectResult = struct {
    result: []const u8 = "",
    @"type": []const u8 = "",
    children: []const Variable = &.{},
    result_allocated: bool = false,
    children_allocated: bool = false,

    pub fn deinit(self: *const InspectResult, allocator: std.mem.Allocator) void {
        if (self.result_allocated) {
            if (self.result.len > 0) allocator.free(self.result);
            if (self.@"type".len > 0) allocator.free(self.@"type");
        }
        if (self.children_allocated) {
            for (self.children) |child| {
                if (child.name.len > 0) allocator.free(child.name);
                if (child.value.len > 0) allocator.free(child.value);
                if (child.@"type".len > 0) allocator.free(child.@"type");
                if (child.evaluate_name.len > 0) allocator.free(child.evaluate_name);
                if (child.memory_reference.len > 0) allocator.free(child.memory_reference);
                if (child.presentation_hint) |ph| {
                    if (ph.kind.len > 0) allocator.free(ph.kind);
                    for (ph.attributes) |attr| allocator.free(attr);
                    if (ph.attributes.len > 0) allocator.free(ph.attributes);
                    if (ph.visibility.len > 0) allocator.free(ph.visibility);
                }
            }
            allocator.free(self.children);
        }
    }

    pub fn jsonStringify(self: *const InspectResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("result");
        try jw.write(self.result);
        if (self.@"type".len > 0) {
            try jw.objectField("type");
            try jw.write(self.@"type");
        }
        if (self.children.len > 0) {
            try jw.objectField("children");
            try jw.beginArray();
            for (self.children) |*c| {
                try c.jsonStringify(jw);
            }
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const SteppingGranularity = enum {
    statement,
    line,
    instruction,

    pub fn parse(s: []const u8) ?SteppingGranularity {
        if (std.mem.eql(u8, s, "statement")) return .statement;
        if (std.mem.eql(u8, s, "line")) return .line;
        if (std.mem.eql(u8, s, "instruction")) return .instruction;
        return null;
    }

    pub fn jsonStringify(self: *const SteppingGranularity, jw: anytype) !void {
        try jw.write(@tagName(self.*));
    }
};

pub const EvaluateContext = enum {
    watch,
    repl,
    hover,
    clipboard,
    variables,

    pub fn parse(s: []const u8) ?EvaluateContext {
        if (std.mem.eql(u8, s, "watch")) return .watch;
        if (std.mem.eql(u8, s, "repl")) return .repl;
        if (std.mem.eql(u8, s, "hover")) return .hover;
        if (std.mem.eql(u8, s, "clipboard")) return .clipboard;
        if (std.mem.eql(u8, s, "variables")) return .variables;
        return null;
    }
};

pub const InstructionBreakpoint = struct {
    instruction_reference: []const u8,
    offset: ?i64 = null,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,

    pub fn jsonStringify(self: *const InstructionBreakpoint, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("instructionReference");
        try jw.write(self.instruction_reference);
        if (self.offset) |o| {
            try jw.objectField("offset");
            try jw.write(o);
        }
        if (self.condition) |c| {
            try jw.objectField("condition");
            try jw.write(c);
        }
        if (self.hit_condition) |h| {
            try jw.objectField("hitCondition");
            try jw.write(h);
        }
        try jw.endObject();
    }
};

pub const BreakpointLocation = struct {
    line: u32,
    column: ?u32 = null,
    end_line: ?u32 = null,
    end_column: ?u32 = null,

    pub fn jsonStringify(self: *const BreakpointLocation, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("line");
        try jw.write(self.line);
        if (self.column) |c| {
            try jw.objectField("column");
            try jw.write(c);
        }
        if (self.end_line) |el| {
            try jw.objectField("endLine");
            try jw.write(el);
        }
        if (self.end_column) |ec| {
            try jw.objectField("endColumn");
            try jw.write(ec);
        }
        try jw.endObject();
    }
};

pub const StepInTarget = struct {
    id: u32,
    label: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    end_line: ?u32 = null,
    end_column: ?u32 = null,

    pub fn jsonStringify(self: *const StepInTarget, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("label");
        try jw.write(self.label);
        if (self.line) |l| {
            try jw.objectField("line");
            try jw.write(l);
        }
        if (self.column) |c| {
            try jw.objectField("column");
            try jw.write(c);
        }
        if (self.end_line) |el| {
            try jw.objectField("endLine");
            try jw.write(el);
        }
        if (self.end_column) |ec| {
            try jw.objectField("endColumn");
            try jw.write(ec);
        }
        try jw.endObject();
    }
};

pub const StackFrameFormat = struct {
    parameters: ?bool = null,
    parameter_types: ?bool = null,
    parameter_names: ?bool = null,
    parameter_values: ?bool = null,
    line: ?bool = null,
    module: ?bool = null,
    include_all: ?bool = null,

    pub fn jsonStringify(self: *const StackFrameFormat, jw: anytype) !void {
        try jw.beginObject();
        if (self.parameters) |v| {
            try jw.objectField("parameters");
            try jw.write(v);
        }
        if (self.parameter_types) |v| {
            try jw.objectField("parameterTypes");
            try jw.write(v);
        }
        if (self.parameter_names) |v| {
            try jw.objectField("parameterNames");
            try jw.write(v);
        }
        if (self.parameter_values) |v| {
            try jw.objectField("parameterValues");
            try jw.write(v);
        }
        if (self.line) |v| {
            try jw.objectField("line");
            try jw.write(v);
        }
        if (self.module) |v| {
            try jw.objectField("module");
            try jw.write(v);
        }
        if (self.include_all) |v| {
            try jw.objectField("includeAll");
            try jw.write(v);
        }
        try jw.endObject();
    }
};

pub const ValueFormat = struct {
    hex: ?bool = null,

    pub fn jsonStringify(self: *const ValueFormat, jw: anytype) !void {
        try jw.beginObject();
        if (self.hex) |v| {
            try jw.objectField("hex");
            try jw.write(v);
        }
        try jw.endObject();
    }
};

pub const VariablePresentationHint = struct {
    kind: []const u8 = "",
    attributes: []const []const u8 = &.{},
    visibility: []const u8 = "",

    pub fn jsonStringify(self: *const VariablePresentationHint, jw: anytype) !void {
        try jw.beginObject();
        if (self.kind.len > 0) {
            try jw.objectField("kind");
            try jw.write(self.kind);
        }
        if (self.attributes.len > 0) {
            try jw.objectField("attributes");
            try jw.beginArray();
            for (self.attributes) |attr| {
                try jw.write(attr);
            }
            try jw.endArray();
        }
        if (self.visibility.len > 0) {
            try jw.objectField("visibility");
            try jw.write(self.visibility);
        }
        try jw.endObject();
    }
};

pub const VariableFilter = enum {
    indexed,
    named,

    pub fn parse(s: []const u8) ?VariableFilter {
        if (std.mem.eql(u8, s, "indexed")) return .indexed;
        if (std.mem.eql(u8, s, "named")) return .named;
        return null;
    }
};


pub const GotoTarget = struct {
    id: u32,
    label: []const u8,
    line: u32,
    column: ?u32 = null,
    end_line: ?u32 = null,
    end_column: ?u32 = null,

    pub fn jsonStringify(self: *const GotoTarget, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("label");
        try jw.write(self.label);
        try jw.objectField("line");
        try jw.write(self.line);
        if (self.column) |c| {
            try jw.objectField("column");
            try jw.write(c);
        }
        if (self.end_line) |el| {
            try jw.objectField("endLine");
            try jw.write(el);
        }
        if (self.end_column) |ec| {
            try jw.objectField("endColumn");
            try jw.write(ec);
        }
        try jw.endObject();
    }
};

pub const SymbolInfo = struct {
    name: []const u8,
    kind: []const u8 = "",
    file: []const u8 = "",
    line: ?u32 = null,
    container: []const u8 = "",

    pub fn jsonStringify(self: *const SymbolInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.kind.len > 0) {
            try jw.objectField("kind");
            try jw.write(self.kind);
        }
        if (self.file.len > 0) {
            try jw.objectField("file");
            try jw.write(self.file);
        }
        if (self.line) |l| {
            try jw.objectField("line");
            try jw.write(l);
        }
        if (self.container.len > 0) {
            try jw.objectField("container");
            try jw.write(self.container);
        }
        try jw.endObject();
    }
};

pub const VariableLocationInfo = struct {
    name: []const u8,
    location_type: []const u8 = "", // "register", "stack", "optimized_out", "split", "constant"
    register: []const u8 = "",
    stack_offset: ?i64 = null,
    address: ?u64 = null,
    pieces: []const u8 = "", // For split locations

    pub fn jsonStringify(self: *const VariableLocationInfo, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("location_type");
        try jw.write(self.location_type);
        if (self.register.len > 0) {
            try jw.objectField("register");
            try jw.write(self.register);
        }
        if (self.stack_offset) |off| {
            try jw.objectField("stack_offset");
            try jw.write(off);
        }
        if (self.address) |addr| {
            try jw.objectField("address");
            var buf: [18]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "0x{x}", .{addr}) catch "0x0";
            try jw.write(hex);
        }
        if (self.pieces.len > 0) {
            try jw.objectField("pieces");
            try jw.write(self.pieces);
        }
        try jw.endObject();
    }
};

pub const DebugNotification = struct {
    method: []const u8,
    params_json: []const u8,

    pub fn jsonStringify(self: *const DebugNotification, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write(self.method);
        try jw.objectField("params");
        try jw.writer.writeAll(self.params_json);
        try jw.endObject();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

fn stringifyToString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: json.Stringify = .{ .writer = &aw.writer };
    try value.jsonStringify(&jw);
    return try aw.toOwnedSlice();
}

test "StackFrame serializes to JSON correctly" {
    const allocator = std.testing.allocator;
    const frame = StackFrame{
        .id = 0,
        .name = "main",
        .source = "test.py",
        .line = 42,
        .column = 1,
    };
    const result = try stringifyToString(allocator, frame);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("test.py", parsed.value.object.get("source").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("line").?.integer);
}

test "Variable serializes with variablesReference" {
    const allocator = std.testing.allocator;
    const v = Variable{
        .name = "data",
        .value = "{...}",
        .@"type" = "dict",
        .children_count = 3,
        .variables_reference = 7,
    };
    const result = try stringifyToString(allocator, v);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("data", parsed.value.object.get("name").?.string);
    try std.testing.expect(parsed.value.object.get("children_count") == null);
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("variablesReference").?.integer);
}

test "StopState includes location and locals" {
    const allocator = std.testing.allocator;
    const locals = [_]Variable{
        .{ .name = "x", .value = "42", .@"type" = "int" },
    };
    const state = StopState{
        .stop_reason = .breakpoint,
        .location = .{ .file = "main.py", .line = 42, .function = "process" },
        .locals = &locals,
    };
    const result = try stringifyToString(allocator, state);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("breakpoint", obj.get("stop_reason").?.string);
    // Note: stop_reason is a StopState field, not StopReason's own serialization
    const loc = obj.get("location").?.object;
    try std.testing.expectEqualStrings("main.py", loc.get("file").?.string);
    try std.testing.expectEqual(@as(i64, 42), loc.get("line").?.integer);
}

test "LaunchConfig parses from JSON with defaults" {
    const allocator = std.testing.allocator;
    const input = "{\"program\": \"/usr/bin/python3\", \"args\": [\"script.py\"]}";

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();

    const config = try LaunchConfig.parseFromJson(allocator, parsed.value);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("/usr/bin/python3", config.program);
    try std.testing.expectEqual(@as(usize, 1), config.args.len);
    try std.testing.expectEqualStrings("script.py", config.args[0]);
    try std.testing.expect(!config.stop_on_entry);
    try std.testing.expect(config.language == null);
}

test "RunAction parses all valid action strings" {
    try std.testing.expectEqual(RunAction.@"continue", RunAction.parse("continue").?);
    try std.testing.expectEqual(RunAction.step_into, RunAction.parse("step_into").?);
    try std.testing.expectEqual(RunAction.step_over, RunAction.parse("step_over").?);
    try std.testing.expectEqual(RunAction.step_out, RunAction.parse("step_out").?);
    try std.testing.expectEqual(RunAction.restart, RunAction.parse("restart").?);
}

test "RunAction rejects invalid action string" {
    try std.testing.expect(RunAction.parse("invalid") == null);
    try std.testing.expect(RunAction.parse("") == null);
    try std.testing.expect(RunAction.parse("CONTINUE") == null);
}

test "SteppingGranularity.parse parses all variants" {
    try std.testing.expectEqual(SteppingGranularity.statement, SteppingGranularity.parse("statement").?);
    try std.testing.expectEqual(SteppingGranularity.line, SteppingGranularity.parse("line").?);
    try std.testing.expectEqual(SteppingGranularity.instruction, SteppingGranularity.parse("instruction").?);
    try std.testing.expect(SteppingGranularity.parse("invalid") == null);
}

test "EvaluateContext.parse parses all variants" {
    try std.testing.expectEqual(EvaluateContext.watch, EvaluateContext.parse("watch").?);
    try std.testing.expectEqual(EvaluateContext.repl, EvaluateContext.parse("repl").?);
    try std.testing.expectEqual(EvaluateContext.hover, EvaluateContext.parse("hover").?);
    try std.testing.expectEqual(EvaluateContext.clipboard, EvaluateContext.parse("clipboard").?);
    try std.testing.expectEqual(EvaluateContext.variables, EvaluateContext.parse("variables").?);
    try std.testing.expect(EvaluateContext.parse("invalid") == null);
}

test "VariableFilter.parse parses all variants" {
    try std.testing.expectEqual(VariableFilter.indexed, VariableFilter.parse("indexed").?);
    try std.testing.expectEqual(VariableFilter.named, VariableFilter.parse("named").?);
    try std.testing.expect(VariableFilter.parse("invalid") == null);
}

test "BreakpointInfo serializes with DAP source object" {
    const allocator = std.testing.allocator;
    const bp = BreakpointInfo{
        .id = 1,
        .verified = true,
        .file = "main.zig",
        .line = 10,
        .actual_line = 12,
    };
    const result = try stringifyToString(allocator, bp);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
    try std.testing.expect(obj.get("verified").?.bool);
    const source = obj.get("source").?.object;
    try std.testing.expectEqualStrings("main.zig", source.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 12), obj.get("line").?.integer);
}

test "DebugCapabilities serializes new flags when true" {
    const allocator = std.testing.allocator;
    const caps = DebugCapabilities{
        .supports_instruction_breakpoints = true,
        .supports_stepping_granularity = true,
        .supports_cancel_request = true,
        .supports_terminate_threads = true,
        .supports_breakpoint_locations = true,
        .supports_step_in_targets = true,
        .supports_evaluate_for_hovers = true,
        .supports_value_formatting = true,
        .supports_loaded_sources = true,
        .supports_restart_request = true,
        .supports_single_thread_execution_requests = true,
    };
    const result = try stringifyToString(allocator, caps);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expect(obj.get("supportsInstructionBreakpoints").?.bool);
    try std.testing.expect(obj.get("supportsSteppingGranularity").?.bool);
    try std.testing.expect(obj.get("supportsCancelRequest").?.bool);
    try std.testing.expect(obj.get("supportsTerminateThreadsRequest").?.bool);
    try std.testing.expect(obj.get("supportsBreakpointLocationsRequest").?.bool);
    try std.testing.expect(obj.get("supportsStepInTargetsRequest").?.bool);
    try std.testing.expect(obj.get("supportsEvaluateForHovers").?.bool);
    try std.testing.expect(obj.get("supportsValueFormattingOptions").?.bool);
    try std.testing.expect(obj.get("supportsLoadedSourcesRequest").?.bool);
    try std.testing.expect(obj.get("supportsRestartRequest").?.bool);
    try std.testing.expect(obj.get("supportsSingleThreadExecutionRequests").?.bool);
}
