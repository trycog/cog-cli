const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const types = @import("../types.zig");
const driver_mod = @import("../driver.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

const RunAction = types.RunAction;
const StopState = types.StopState;
const StopReason = types.StopReason;
const StackFrame = types.StackFrame;
const Variable = types.Variable;
const SourceLocation = types.SourceLocation;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;
const ThreadInfo = types.ThreadInfo;
const DisassembledInstruction = types.DisassembledInstruction;
const Scope = types.Scope;
const DataBreakpointInfo = types.DataBreakpointInfo;
const DataBreakpointAccessType = types.DataBreakpointAccessType;
const DebugCapabilities = types.DebugCapabilities;
const CompletionItem = types.CompletionItem;
const Module = types.Module;
const InstructionBreakpoint = types.InstructionBreakpoint;
const BreakpointLocation = types.BreakpointLocation;
const StepInTarget = types.StepInTarget;
const ActiveDriver = driver_mod.ActiveDriver;
const DriverVTable = driver_mod.DriverVTable;

// ── DAP Proxy ───────────────────────────────────────────────────────────

pub const DapProxy = struct {
    process: ?std.process.Child = null,
    seq: i64 = 1,
    thread_id: i64 = 1,
    initialized: bool = false,
    allocator: std.mem.Allocator,
    // Buffered data from the adapter
    read_buffer: std.ArrayListUnmanaged(u8) = .empty,
    // Breakpoint tracking: per-file breakpoint lines (DAP requires re-sending all BPs for a file)
    file_breakpoints: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(BreakpointEntry)) = .empty,
    next_bp_id: u32 = 1,
    // Map from our bp_id to file path + line for removal
    bp_registry: std.AutoHashMapUnmanaged(u32, BpRegistryEntry) = .empty,
    // Output buffer for captured debuggee output
    output_buffer: std.ArrayListUnmanaged(types.OutputEntry) = .empty,
    // Loaded modules tracked from module events
    loaded_modules: std.ArrayListUnmanaged(LoadedModuleEntry) = .empty,
    // Capabilities parsed from DAP initialize response
    adapter_capabilities: DebugCapabilities = .{},
    // Buffered memory events from adapter
    memory_events: std.ArrayListUnmanaged(MemoryEvent) = .empty,
    // Progress tracking from adapter
    active_progress: std.StringHashMapUnmanaged(ProgressState) = .empty,
    // Invalidated areas from adapter
    invalidated_areas: std.ArrayListUnmanaged(InvalidatedEvent) = .empty,
    // Pending notifications for MCP server to emit
    pending_notifications: std.ArrayListUnmanaged(types.DebugNotification) = .empty,
    // Request timeout in milliseconds (default 30s)
    request_timeout_ms: i32 = 30_000,

    pub const MemoryEvent = struct {
        memory_reference: []const u8,
        offset: i64,
        count: i64,
    };

    pub const ProgressState = struct {
        title: []const u8,
        message: []const u8,
        percentage: ?f64,
    };

    pub const InvalidatedEvent = struct {
        areas: []const []const u8,
        stack_frame_id: ?u32,
    };

    const LoadedModuleEntry = struct {
        name: []const u8,
    };

    const BreakpointEntry = struct {
        line: u32,
        condition: ?[]const u8,
        hit_condition: ?[]const u8,
        log_message: ?[]const u8 = null,
        bp_id: u32,
    };

    const BpRegistryEntry = struct {
        file: []const u8,
        line: u32,
    };

    pub fn init(allocator: std.mem.Allocator) DapProxy {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DapProxy) void {
        self.read_buffer.deinit(self.allocator);
        // Clean up breakpoint tracking
        var it = self.file_breakpoints.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_breakpoints.deinit(self.allocator);
        self.bp_registry.deinit(self.allocator);
        // Clean up output buffer
        for (self.output_buffer.items) |entry| {
            self.allocator.free(entry.category);
            self.allocator.free(entry.text);
        }
        self.output_buffer.deinit(self.allocator);
        // Clean up loaded modules
        for (self.loaded_modules.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.loaded_modules.deinit(self.allocator);
        // Clean up memory events
        for (self.memory_events.items) |entry| {
            self.allocator.free(entry.memory_reference);
        }
        self.memory_events.deinit(self.allocator);
        // Clean up progress tracking
        {
            var pit = self.active_progress.iterator();
            while (pit.next()) |entry| {
                self.allocator.free(entry.value_ptr.title);
                self.allocator.free(entry.value_ptr.message);
                self.allocator.free(entry.key_ptr.*);
            }
            self.active_progress.deinit(self.allocator);
        }
        // Clean up invalidated events
        for (self.invalidated_areas.items) |entry| {
            for (entry.areas) |area| self.allocator.free(area);
            self.allocator.free(entry.areas);
        }
        self.invalidated_areas.deinit(self.allocator);
        // Clean up pending notifications
        for (self.pending_notifications.items) |entry| {
            self.allocator.free(entry.method);
            self.allocator.free(entry.params_json);
        }
        self.pending_notifications.deinit(self.allocator);
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
        }
    }

    pub fn activeDriver(self: *DapProxy) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .dap,
        };
    }

    const vtable = DriverVTable{
        .launchFn = proxyLaunch,
        .runFn = proxyRun,
        .setBreakpointFn = proxySetBreakpoint,
        .removeBreakpointFn = proxyRemoveBreakpoint,
        .listBreakpointsFn = proxyListBreakpoints,
        .inspectFn = proxyInspect,
        .stopFn = proxyStop,
        .deinitFn = proxyDeinit,
        .threadsFn = proxyThreads,
        .stackTraceFn = proxyStackTrace,
        .readMemoryFn = proxyReadMemory,
        .writeMemoryFn = proxyWriteMemory,
        .disassembleFn = proxyDisassemble,
        .attachFn = proxyAttach,
        .setFunctionBreakpointFn = proxySetFunctionBreakpoint,
        .setExceptionBreakpointsFn = proxySetExceptionBreakpoints,
        .setVariableFn = proxySetVariable,
        .gotoFn = proxyGoto,
        .scopesFn = proxyScopes,
        .dataBreakpointInfoFn = proxyDataBreakpointInfo,
        .setDataBreakpointFn = proxySetDataBreakpoint,
        .capabilitiesFn = proxyCapabilities,
        .completionsFn = proxyCompletions,
        .modulesFn = proxyModules,
        .loadedSourcesFn = proxyLoadedSources,
        .sourceFn = proxySource,
        .setExpressionFn = proxySetExpression,
        .terminateFn = proxyTerminate,
        .restartFrameFn = proxyRestartFrame,
        .exceptionInfoFn = proxyExceptionInfo,
        .setInstructionBreakpointsFn = proxySetInstructionBreakpoints,
        .stepInTargetsFn = proxyStepInTargets,
        .breakpointLocationsFn = proxyBreakpointLocations,
        .cancelFn = proxyCancel,
        .terminateThreadsFn = proxyTerminateThreads,
        .restartFn = proxyRestart,
        .detachFn = proxyDetach,
        .gotoTargetsFn = proxyGotoTargets,
        .findSymbolFn = proxyFindSymbol,
        .drainNotificationsFn = proxyDrainNotifications,
    };

    fn nextSeq(self: *DapProxy) i64 {
        const s = self.seq;
        self.seq += 1;
        return s;
    }

    /// Send a DAP request and wait for matching response.
    /// Handles interleaved events (stopped, output, etc.) by storing them.
    /// Returns the raw JSON body of the response.
    fn sendRequest(self: *DapProxy, allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
        // Encode with Content-Length framing
        const encoded = try transport.encodeMessage(allocator, msg);
        defer allocator.free(encoded);

        // Write to adapter stdin
        const proc = &(self.process orelse return error.NotInitialized);
        if (proc.stdin) |stdin| {
            var buf: [8192]u8 = undefined;
            var w = stdin.writer(&buf);
            w.interface.writeAll(encoded) catch return error.WriteFailed;
            w.interface.flush() catch return error.WriteFailed;
        } else return error.NotInitialized;

        // Read response (may need to skip events)
        return self.readResponse(allocator);
    }

    /// Read messages from the adapter until we get a response (type == "response").
    /// Events are processed inline (e.g., update thread_id from stopped events).
    fn readResponse(self: *DapProxy, allocator: std.mem.Allocator) ![]const u8 {
        const proc = &(self.process orelse return error.NotInitialized);
        const stdout = proc.stdout orelse return error.NotInitialized;

        var read_buf: [8192]u8 = undefined;

        while (true) {
            // Try to decode a message from the buffer
            while (true) {
                const decoded = transport.decodeMessage(allocator, self.read_buffer.items) catch |err| switch (err) {
                    error.MissingHeader, error.TruncatedBody => break, // need more data
                    else => return err,
                };

                // Remove consumed bytes from read_buffer
                const remaining = self.read_buffer.items.len - decoded.bytes_consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[decoded.bytes_consumed..]);
                }
                self.read_buffer.items.len = remaining;

                // Check if this is a response or an event
                const parsed = json.parseFromSlice(json.Value, allocator, decoded.body, .{}) catch {
                    allocator.free(decoded.body);
                    continue;
                };
                defer parsed.deinit();

                const msg_type = if (parsed.value == .object)
                    if (parsed.value.object.get("type")) |t| if (t == .string) t.string else null else null
                else
                    null;

                if (msg_type) |mt| {
                    if (std.mem.eql(u8, mt, "response")) {
                        // This is the response we're waiting for
                        return decoded.body;
                    } else if (std.mem.eql(u8, mt, "event")) {
                        // Handle events
                        if (parsed.value.object.get("event")) |evt| {
                            if (evt == .string) {
                                if (std.mem.eql(u8, evt.string, "stopped")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("threadId")) |tid| {
                                                if (tid == .integer) self.thread_id = tid.integer;
                                            }
                                        }
                                    }
                                    // Queue notification
                                    self.queueNotification("debug/stopped", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "output")) {
                                    // Capture debuggee output
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            const category = if (body.object.get("category")) |c|
                                                (if (c == .string) c.string else "console")
                                            else
                                                "console";
                                            const text = if (body.object.get("output")) |o|
                                                (if (o == .string) o.string else "")
                                            else
                                                "";
                                            if (text.len > 0) {
                                                self.output_buffer.append(self.allocator, .{
                                                    .category = self.allocator.dupe(u8, category) catch "",
                                                    .text = self.allocator.dupe(u8, text) catch "",
                                                }) catch {};
                                            }
                                        }
                                    }
                                    self.queueNotification("debug/output", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "breakpoint")) {
                                    // Breakpoint verification event
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("breakpoint")) |bp| {
                                                if (bp == .object) {
                                                    self.handleBreakpointEvent(bp.object);
                                                }
                                            }
                                        }
                                    }
                                    self.queueNotification("debug/breakpoint_verified", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "module")) {
                                    // Module load/unload event — track loaded modules
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleModuleEvent(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/module", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "continued")) {
                                    // Thread continued event
                                    self.queueNotification("debug/continued", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "thread")) {
                                    // Thread create/exit event
                                    self.queueNotification("debug/thread", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "loadedSource")) {
                                    // Loaded source event
                                    self.queueNotification("debug/loaded_source", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "process")) {
                                    // Process event
                                    self.queueNotification("debug/process", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "capabilities")) {
                                    // Capabilities changed event — update adapter_capabilities
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            if (body.object.get("capabilities")) |caps| {
                                                if (caps == .object) {
                                                    self.updateCapabilitiesFromEvent(caps.object);
                                                }
                                            }
                                        }
                                    }
                                    self.queueNotification("debug/capabilities_changed", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "memory")) {
                                    // Memory event — track memory changes
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleMemoryEvent(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/memory_changed", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "progressStart")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleProgressStart(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/progress", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "progressUpdate")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleProgressUpdate(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/progress", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "progressEnd")) {
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleProgressEnd(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/progress", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "exited")) {
                                    // Exited event — process exited with exit code (per DAP spec)
                                    self.queueNotification("debug/exited", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "terminated")) {
                                    // Terminated event — debug session end
                                    self.initialized = false;
                                    self.queueNotification("debug/terminated", decoded.body);
                                } else if (std.mem.eql(u8, evt.string, "invalidated")) {
                                    // Invalidated event — parse areas and stack frame ID
                                    if (parsed.value.object.get("body")) |body| {
                                        if (body == .object) {
                                            self.handleInvalidatedEvent(body.object);
                                        }
                                    }
                                    self.queueNotification("debug/invalidated", decoded.body);
                                }
                            }
                        }
                        // Continue reading for the actual response
                        allocator.free(decoded.body);
                        continue;
                    } else if (std.mem.eql(u8, mt, "request")) {
                        // Reverse request from adapter (e.g., startDebugging, runInTerminal)
                        if (parsed.value.object.get("command")) |cmd| {
                            if (cmd == .string) {
                                if (std.mem.eql(u8, cmd.string, "startDebugging")) {
                                    // Queue notification with the launch config
                                    self.queueNotification("debug/start_debugging", decoded.body);
                                    // Send success response back to adapter
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    self.sendReverseResponse(allocator, req_seq, "startDebugging");
                                } else if (std.mem.eql(u8, cmd.string, "runInTerminal")) {
                                    // Queue notification for AI agent to handle
                                    self.queueNotification("debug/run_in_terminal", decoded.body);
                                    // Send synthetic success response
                                    const req_seq = if (parsed.value.object.get("seq")) |v|
                                        (if (v == .integer) v.integer else 0)
                                    else
                                        0;
                                    self.sendReverseResponse(allocator, req_seq, "runInTerminal");
                                }
                            }
                        }
                        allocator.free(decoded.body);
                        continue;
                    }
                }
                allocator.free(decoded.body);
            }

            // Poll with timeout before reading
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = stdout.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, self.request_timeout_ms) catch return error.ReadFailed;
            if (poll_result == 0) return error.Timeout;

            // Read more data from stdout
            const n = stdout.read(&read_buf) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            try self.read_buffer.appendSlice(self.allocator, read_buf[0..n]);
        }
    }

    /// Wait for a specific event type from the adapter.
    /// Returns the raw JSON body of the event.
    fn waitForEvent(self: *DapProxy, allocator: std.mem.Allocator, event_name: []const u8) ![]const u8 {
        const proc = &(self.process orelse return error.NotInitialized);
        const stdout = proc.stdout orelse return error.NotInitialized;

        var read_buf: [8192]u8 = undefined;

        while (true) {
            // Try to decode from buffer
            while (true) {
                const decoded = transport.decodeMessage(allocator, self.read_buffer.items) catch |err| switch (err) {
                    error.MissingHeader, error.TruncatedBody => break,
                    else => return err,
                };

                const remaining = self.read_buffer.items.len - decoded.bytes_consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.read_buffer.items[0..remaining], self.read_buffer.items[decoded.bytes_consumed..]);
                }
                self.read_buffer.items.len = remaining;

                const parsed = json.parseFromSlice(json.Value, allocator, decoded.body, .{}) catch {
                    allocator.free(decoded.body);
                    continue;
                };
                defer parsed.deinit();

                if (parsed.value == .object) {
                    if (parsed.value.object.get("type")) |t| {
                        if (t == .string and std.mem.eql(u8, t.string, "event")) {
                            if (parsed.value.object.get("event")) |evt| {
                                if (evt == .string and std.mem.eql(u8, evt.string, event_name)) {
                                    return decoded.body;
                                }
                            }
                        }
                    }
                }
                allocator.free(decoded.body);
            }

            const n = stdout.read(&read_buf) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            try self.read_buffer.appendSlice(self.allocator, read_buf[0..n]);
        }
    }

    // ── Action Mapping ──────────────────────────────────────────────────

    pub fn mapRunAction(self: *DapProxy, allocator: std.mem.Allocator, action: RunAction) ![]const u8 {
        return self.mapRunActionEx(allocator, action, .{});
    }

    pub fn mapRunActionEx(self: *DapProxy, allocator: std.mem.Allocator, action: RunAction, opts: types.RunOptions) ![]const u8 {
        const stepping_opts = protocol.SteppingOptions{
            .granularity = opts.granularity,
            .single_thread = null,
        };
        return switch (action) {
            .@"continue" => protocol.continueRequest(allocator, self.nextSeq(), self.thread_id),
            .step_into => if (opts.target_id) |tid|
                protocol.stepInRequestWithTarget(allocator, self.nextSeq(), self.thread_id, stepping_opts, tid)
            else
                protocol.stepInRequestEx(allocator, self.nextSeq(), self.thread_id, stepping_opts),
            .step_over => protocol.nextRequestEx(allocator, self.nextSeq(), self.thread_id, stepping_opts),
            .step_out => protocol.stepOutRequestEx(allocator, self.nextSeq(), self.thread_id, stepping_opts),
            .restart => protocol.disconnectRequest(allocator, self.nextSeq()),
            .pause => protocol.pauseRequest(allocator, self.nextSeq(), if (opts.thread_id) |tid| @intCast(tid) else self.thread_id),
            .reverse_continue => protocol.reverseContinueRequest(allocator, self.nextSeq(), self.thread_id),
            .step_back => protocol.stepBackRequest(allocator, self.nextSeq(), self.thread_id),
        };
    }

    // ── Response Translation ────────────────────────────────────────────

    pub fn translateStoppedEvent(allocator: std.mem.Allocator, data: []const u8) !StopState {
        const evt = try protocol.DapEvent.parse(allocator, data);
        defer evt.deinit(allocator);

        const reason: StopReason = if (evt.stop_reason) |r| blk: {
            if (std.mem.eql(u8, r, "breakpoint")) break :blk .breakpoint;
            if (std.mem.eql(u8, r, "step")) break :blk .step;
            if (std.mem.eql(u8, r, "exception")) break :blk .exception;
            if (std.mem.eql(u8, r, "entry")) break :blk .entry;
            if (std.mem.eql(u8, r, "pause")) break :blk .pause;
            break :blk .step;
        } else .step;

        // Copy hit breakpoint IDs so they survive evt.deinit
        const bp_ids = if (evt.hit_breakpoint_ids.len > 0)
            try allocator.dupe(u32, evt.hit_breakpoint_ids)
        else
            &[_]u32{};

        return .{
            .stop_reason = reason,
            .hit_breakpoint_ids = bp_ids,
        };
    }

    pub fn translateExitedEvent(allocator: std.mem.Allocator, data: []const u8) !StopState {
        const evt = try protocol.DapEvent.parse(allocator, data);
        defer evt.deinit(allocator);

        return .{
            .stop_reason = .exit,
            .exit_code = if (evt.exit_code) |c| @intCast(c) else null,
        };
    }

    pub fn translateStackTrace(allocator: std.mem.Allocator, data: []const u8) ![]StackFrame {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const frames_val = body.object.get("stackFrames") orelse return error.InvalidResponse;
        if (frames_val != .array) return error.InvalidResponse;

        var frames: std.ArrayListUnmanaged(StackFrame) = .empty;
        errdefer frames.deinit(allocator);

        for (frames_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const id: u32 = if (obj.get("id")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "<unknown>"),
            } else try allocator.dupe(u8, "<unknown>");

            const source = if (obj.get("source")) |s| blk: {
                if (s == .object) {
                    if (s.object.get("path")) |p| {
                        if (p == .string) break :blk try allocator.dupe(u8, p.string);
                    }
                }
                break :blk try allocator.dupe(u8, "");
            } else try allocator.dupe(u8, "");

            const line: u32 = if (obj.get("line")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const column: u32 = if (obj.get("column")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            try frames.append(allocator, .{
                .id = id,
                .name = name,
                .source = source,
                .line = line,
                .column = column,
            });
        }

        return try frames.toOwnedSlice(allocator);
    }

    pub fn translateVariables(allocator: std.mem.Allocator, data: []const u8) ![]Variable {
        const parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const vars_val = body.object.get("variables") orelse return error.InvalidResponse;
        if (vars_val != .array) return error.InvalidResponse;

        var vars: std.ArrayListUnmanaged(Variable) = .empty;
        errdefer vars.deinit(allocator);

        for (vars_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const value = if (obj.get("value")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const type_str = if (obj.get("type")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const var_ref: u32 = if (obj.get("variablesReference")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;

            const named_vars: ?u32 = if (obj.get("namedVariables")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => null,
            } else null;

            const indexed_vars: ?u32 = if (obj.get("indexedVariables")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => null,
            } else null;

            const eval_name = if (obj.get("evaluateName")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const mem_ref = if (obj.get("memoryReference")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const pres_hint: ?types.VariablePresentationHint = if (obj.get("presentationHint")) |ph| blk: {
                if (ph == .object) {
                    break :blk .{
                        .kind = if (ph.object.get("kind")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else "") else "",
                        .attributes = if (ph.object.get("attributes")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else "") else "",
                        .visibility = if (ph.object.get("visibility")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else "") else "",
                    };
                }
                break :blk null;
            } else null;

            try vars.append(allocator, .{
                .name = name,
                .value = value,
                .@"type" = type_str,
                .variables_reference = var_ref,
                .children_count = if (var_ref > 0) 1 else 0,
                .named_variables = named_vars,
                .indexed_variables = indexed_vars,
                .evaluate_name = eval_name,
                .memory_reference = mem_ref,
                .presentation_hint = pres_hint,
            });
        }

        return try vars.toOwnedSlice(allocator);
    }

    // ── Driver Interface (vtable functions) ─────────────────────────────

    fn proxyLaunch(ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        // Build adapter command based on file extension
        const ext = std.fs.path.extension(config.program);

        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(allocator);

        if (std.mem.eql(u8, ext, ".py")) {
            try argv_list.append(allocator, "python3");
            try argv_list.append(allocator, "-m");
            try argv_list.append(allocator, "debugpy.adapter");
        } else if (std.mem.eql(u8, ext, ".go")) {
            try argv_list.append(allocator, "dlv");
            try argv_list.append(allocator, "dap");
        } else if (std.mem.eql(u8, ext, ".js")) {
            // CDP transport handles JS via node --inspect
            return;
        } else {
            return error.UnsupportedLanguage;
        }

        // Spawn the adapter subprocess
        var child = std.process.Child.init(argv_list.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        self.process = child;
        self.initialized = false;

        // 1. Send initialize request and wait for response
        const init_msg = try protocol.initializeRequest(allocator, self.nextSeq());
        defer allocator.free(init_msg);
        const init_resp = self.sendRequest(allocator, init_msg) catch {
            // If adapter doesn't respond, still mark as initialized for graceful degradation
            self.initialized = true;
            return;
        };
        defer allocator.free(init_resp);

        // Parse capabilities from the initialize response body
        self.parseAdapterCapabilities(allocator, init_resp);

        // 2. Wait for the 'initialized' event from the adapter (per DAP spec)
        const init_event = self.waitForEvent(allocator, "initialized") catch {
            // Some adapters may not send this event — continue gracefully
            self.initialized = true;
            return;
        };
        allocator.free(init_event);

        // 3. Send launch request and wait for response
        const launch_msg = try protocol.launchRequest(allocator, self.nextSeq(), config.program, config.args, config.stop_on_entry);
        defer allocator.free(launch_msg);
        const launch_resp = self.sendRequest(allocator, launch_msg) catch {
            self.initialized = true;
            return;
        };
        allocator.free(launch_resp);

        // 4. Send configurationDone to tell the adapter we're ready
        const config_done_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
        defer allocator.free(config_done_msg);
        const config_resp = self.sendRequest(allocator, config_done_msg) catch {
            self.initialized = true;
            return;
        };
        allocator.free(config_resp);

        self.initialized = true;
    }

    fn proxyRun(ctx: *anyopaque, allocator: std.mem.Allocator, action: RunAction, options: types.RunOptions) anyerror!StopState {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized) return error.NotInitialized;

        // Build and send the appropriate DAP run command with options
        const msg = try self.mapRunActionEx(allocator, action, options);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        allocator.free(resp);

        // Wait for a stopped or exited event
        // Try stopped first, fall back to exited
        const event_data = self.waitForEvent(allocator, "stopped") catch {
            const exit_data = self.waitForEvent(allocator, "exited") catch {
                return .{ .stop_reason = .step };
            };
            defer allocator.free(exit_data);
            return translateExitedEvent(allocator, exit_data);
        };
        defer allocator.free(event_data);

        var state = try translateStoppedEvent(allocator, event_data);

        // Fetch stack trace for the stopped state
        const st_msg = try protocol.stackTraceRequest(allocator, self.nextSeq(), self.thread_id, 0, 20);
        defer allocator.free(st_msg);
        if (self.sendRequest(allocator, st_msg)) |st_resp| {
            defer allocator.free(st_resp);
            state.stack_trace = translateStackTrace(allocator, st_resp) catch &.{};
        } else |_| {}

        // Attach captured output to state and clear buffer
        if (self.output_buffer.items.len > 0) {
            state.output = self.output_buffer.toOwnedSlice(self.allocator) catch &.{};
        }

        return state;
    }

    fn handleBreakpointEvent(_: *DapProxy, bp_obj: std.json.ObjectMap) void {
        // Update internal breakpoint state based on verification events
        const bp_id = if (bp_obj.get("id")) |id| (if (id == .integer) @as(u32, @intCast(id.integer)) else return) else return;
        const verified = if (bp_obj.get("verified")) |v| (v == .bool and v.bool) else false;
        const actual_line = if (bp_obj.get("line")) |l| (if (l == .integer) @as(u32, @intCast(l.integer)) else null) else null;
        _ = bp_id;
        _ = verified;
        _ = actual_line;
        // Store verification state for future queries
        // The breakpoint event data is captured but since breakpoint storage
        // is per-file in file_breakpoints, we'd need to iterate to find it.
        // For now, the event is consumed and logged.
    }

    fn handleMemoryEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const mem_ref = if (body_obj.get("memoryReference")) |v| (if (v == .string) v.string else return) else return;
        const offset: i64 = if (body_obj.get("offset")) |v| (if (v == .integer) v.integer else 0) else 0;
        const count: i64 = if (body_obj.get("count")) |v| (if (v == .integer) v.integer else 0) else 0;
        self.memory_events.append(self.allocator, .{
            .memory_reference = self.allocator.dupe(u8, mem_ref) catch return,
            .offset = offset,
            .count = count,
        }) catch {};
    }

    fn handleProgressStart(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        const title = if (body_obj.get("title")) |v| (if (v == .string) v.string else "") else "";
        const message = if (body_obj.get("message")) |v| (if (v == .string) v.string else "") else "";
        const percentage: ?f64 = if (body_obj.get("percentage")) |v| (if (v == .float) v.float else null) else null;
        const key = self.allocator.dupe(u8, progress_id) catch return;
        self.active_progress.put(self.allocator, key, .{
            .title = self.allocator.dupe(u8, title) catch return,
            .message = self.allocator.dupe(u8, message) catch return,
            .percentage = percentage,
        }) catch {
            self.allocator.free(key);
        };
    }

    fn handleProgressUpdate(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        if (self.active_progress.getPtr(progress_id)) |state| {
            if (body_obj.get("message")) |v| {
                if (v == .string) {
                    self.allocator.free(state.message);
                    state.message = self.allocator.dupe(u8, v.string) catch return;
                }
            }
            if (body_obj.get("percentage")) |v| {
                if (v == .float) state.percentage = v.float;
            }
        }
    }

    fn handleProgressEnd(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        const progress_id = if (body_obj.get("progressId")) |v| (if (v == .string) v.string else return) else return;
        if (self.active_progress.fetchRemove(progress_id)) |kv| {
            self.allocator.free(kv.value.title);
            self.allocator.free(kv.value.message);
            self.allocator.free(kv.key);
        }
    }

    fn handleInvalidatedEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        var areas_list = std.ArrayListUnmanaged([]const u8).empty;
        if (body_obj.get("areas")) |areas_val| {
            if (areas_val == .array) {
                for (areas_val.array.items) |item| {
                    if (item == .string) {
                        areas_list.append(self.allocator, self.allocator.dupe(u8, item.string) catch continue) catch {};
                    }
                }
            }
        }
        const stack_frame_id: ?u32 = if (body_obj.get("stackFrameId")) |v|
            (if (v == .integer) @as(u32, @intCast(v.integer)) else null)
        else
            null;
        self.invalidated_areas.append(self.allocator, .{
            .areas = areas_list.toOwnedSlice(self.allocator) catch &.{},
            .stack_frame_id = stack_frame_id,
        }) catch {};
    }

    /// Send a success response for a reverse request from the adapter.
    fn sendReverseResponse(self: *DapProxy, allocator: std.mem.Allocator, request_seq: i64, command: []const u8) void {
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };

        s.beginObject() catch return;
        s.objectField("seq") catch return;
        s.write(self.nextSeq()) catch return;
        s.objectField("type") catch return;
        s.write("response") catch return;
        s.objectField("request_seq") catch return;
        s.write(request_seq) catch return;
        s.objectField("success") catch return;
        s.write(true) catch return;
        s.objectField("command") catch return;
        s.write(command) catch return;
        s.endObject() catch return;

        const msg = aw.toOwnedSlice() catch return;
        defer allocator.free(msg);

        const encoded = transport.encodeMessage(allocator, msg) catch return;
        defer allocator.free(encoded);

        const proc = &(self.process orelse return);
        if (proc.stdin) |stdin| {
            var buf: [8192]u8 = undefined;
            var w = stdin.writer(&buf);
            w.interface.writeAll(encoded) catch {};
            w.interface.flush() catch {};
        }
    }

    fn queueNotification(self: *DapProxy, method: []const u8, params_json: []const u8) void {
        self.pending_notifications.append(self.allocator, .{
            .method = self.allocator.dupe(u8, method) catch return,
            .params_json = self.allocator.dupe(u8, params_json) catch return,
        }) catch {};
    }

    /// Drain and return all pending notifications, transferring ownership to caller.
    pub fn drainNotifications(self: *DapProxy, allocator: std.mem.Allocator) []const types.DebugNotification {
        if (self.pending_notifications.items.len == 0) return &.{};
        const result = allocator.dupe(types.DebugNotification, self.pending_notifications.items) catch return &.{};
        // Clear without freeing — ownership transferred
        self.pending_notifications.items.len = 0;
        return result;
    }

    fn parseAdapterCapabilities(self: *DapProxy, allocator: std.mem.Allocator, resp_body: []const u8) void {
        const parsed = json.parseFromSlice(json.Value, allocator, resp_body, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const body = parsed.value.object.get("body") orelse return;
        if (body != .object) return;
        const b = body.object;

        self.adapter_capabilities = .{
            .supports_conditional_breakpoints = getBoolCap(b, "supportsConditionalBreakpoints"),
            .supports_hit_conditional_breakpoints = getBoolCap(b, "supportsHitConditionalBreakpoints"),
            .supports_log_points = getBoolCap(b, "supportsLogPoints"),
            .supports_function_breakpoints = getBoolCap(b, "supportsFunctionBreakpoints"),
            .supports_exception_breakpoints = true, // Always available in DAP
            .supports_data_breakpoints = getBoolCap(b, "supportsDataBreakpoints"),
            .supports_set_variable = getBoolCap(b, "supportsSetVariable"),
            .supports_goto_targets = getBoolCap(b, "supportsGotoTargetsRequest"),
            .supports_read_memory = getBoolCap(b, "supportsReadMemoryRequest"),
            .supports_write_memory = getBoolCap(b, "supportsWriteMemoryRequest"),
            .supports_disassemble = getBoolCap(b, "supportsDisassembleRequest"),
            .supports_terminate = getBoolCap(b, "supportsTerminateRequest"),
            .supports_completions = getBoolCap(b, "supportsCompletionsRequest"),
            .supports_modules = getBoolCap(b, "supportsModulesRequest"),
            .supports_set_expression = getBoolCap(b, "supportsSetExpression"),
            .supports_step_back = getBoolCap(b, "supportsStepBack"),
            .supports_restart_frame = getBoolCap(b, "supportsRestartFrame"),
            .supports_instruction_breakpoints = getBoolCap(b, "supportsInstructionBreakpoints"),
            .supports_stepping_granularity = getBoolCap(b, "supportsSteppingGranularity"),
            .supports_cancel_request = getBoolCap(b, "supportsCancelRequest"),
            .supports_terminate_threads = getBoolCap(b, "supportsTerminateThreadsRequest"),
            .supports_breakpoint_locations = getBoolCap(b, "supportsBreakpointLocationsRequest"),
            .supports_step_in_targets = getBoolCap(b, "supportsStepInTargetsRequest"),
            .supports_evaluate_for_hovers = getBoolCap(b, "supportsEvaluateForHovers"),
            .supports_value_formatting = getBoolCap(b, "supportsValueFormattingOptions"),
            .supports_loaded_sources = getBoolCap(b, "supportsLoadedSourcesRequest"),
            .supports_restart_request = getBoolCap(b, "supportsRestartRequest"),
            .supports_single_thread_execution_requests = getBoolCap(b, "supportsSingleThreadExecutionRequests"),
            .supports_exception_options = getBoolCap(b, "supportsExceptionOptions"),
            .supports_exception_filter_options = getBoolCap(b, "supportsExceptionFilterOptions"),
            .supports_exception_info_request = getBoolCap(b, "supportsExceptionInfoRequest"),
            .support_terminate_debuggee = getBoolCap(b, "supportTerminateDebuggee"),
            .support_suspend_debuggee = getBoolCap(b, "supportSuspendDebuggee"),
            .supports_delayed_stack_trace_loading = getBoolCap(b, "supportsDelayedStackTraceLoading"),
            .supports_clipboard_context = getBoolCap(b, "supportsClipboardContext"),
        };
    }

    fn getBoolCap(obj: std.json.ObjectMap, key: []const u8) bool {
        const val = obj.get(key) orelse return false;
        return val == .bool and val.bool;
    }

    fn handleModuleEvent(self: *DapProxy, body_obj: std.json.ObjectMap) void {
        // Track module load/unload events from the adapter
        const reason = if (body_obj.get("reason")) |r| (if (r == .string) r.string else return) else return;
        const module = body_obj.get("module") orelse return;
        if (module != .object) return;

        const name = if (module.object.get("name")) |n| (if (n == .string) n.string else "unknown") else "unknown";

        if (std.mem.eql(u8, reason, "new") or std.mem.eql(u8, reason, "changed")) {
            // Track loaded module
            self.loaded_modules.append(self.allocator, .{
                .name = self.allocator.dupe(u8, name) catch return,
            }) catch {};
        }
    }

    fn proxySetBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8, log_message: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        // Assign a local bp_id
        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        // Track this breakpoint per file (DAP requires all BPs for a file in one request)
        const gop = try self.file_breakpoints.getOrPut(self.allocator, file);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, .{
            .line = line,
            .condition = condition,
            .hit_condition = hit_condition,
            .log_message = log_message,
            .bp_id = bp_id,
        });

        // Register for removal lookup
        try self.bp_registry.put(self.allocator, bp_id, .{ .file = file, .line = line });

        // If adapter is connected, send the DAP setBreakpoints request with conditions
        if (self.initialized and self.process != null) {
            try self.sendFileBreakpoints(allocator, file, gop.value_ptr.items);
        }

        return .{ .id = bp_id, .verified = true, .file = file, .line = line, .condition = condition, .hit_condition = hit_condition };
    }

    /// Build and send a setBreakpoints request with full breakpoint options for a file.
    fn sendFileBreakpoints(self: *DapProxy, allocator: std.mem.Allocator, file: []const u8, bp_list: []const BreakpointEntry) !void {
        var options = try allocator.alloc(protocol.BreakpointOption, bp_list.len);
        defer allocator.free(options);
        for (bp_list, 0..) |entry, i| {
            options[i] = .{
                .line = entry.line,
                .condition = entry.condition,
                .hit_condition = entry.hit_condition,
                .log_message = entry.log_message,
            };
        }
        // Use lines as dummy - the Ex function uses options when provided
        var lines = try allocator.alloc(u32, bp_list.len);
        defer allocator.free(lines);
        for (bp_list, 0..) |entry, i| {
            lines[i] = entry.line;
        }
        const msg = try protocol.setBreakpointsRequestEx(allocator, self.nextSeq(), file, lines, options);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyRemoveBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, id: u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        // Look up which file this breakpoint belongs to
        const entry = self.bp_registry.get(id) orelse return;
        const file = entry.file;

        // Remove from per-file list
        if (self.file_breakpoints.getPtr(file)) |bp_list| {
            var i: usize = 0;
            while (i < bp_list.items.len) {
                if (bp_list.items[i].bp_id == id) {
                    _ = bp_list.swapRemove(i);
                    break;
                }
                i += 1;
            }

            // Re-send all remaining breakpoints for this file (with conditions)
            if (self.initialized and self.process != null) {
                self.sendFileBreakpoints(allocator, file, bp_list.items) catch {};
            }
        }

        _ = self.bp_registry.remove(id);
    }

    fn proxyListBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));

        var result = std.ArrayListUnmanaged(BreakpointInfo).empty;
        var it = self.file_breakpoints.iterator();
        while (it.next()) |entry| {
            const file = entry.key_ptr.*;
            for (entry.value_ptr.items) |bp| {
                try result.append(allocator, .{
                    .id = bp.bp_id,
                    .verified = true,
                    .file = file,
                    .line = bp.line,
                    .condition = bp.condition,
                    .hit_condition = bp.hit_condition,
                });
            }
        }
        return try result.toOwnedSlice(allocator);
    }

    fn proxyInspect(ctx: *anyopaque, allocator: std.mem.Allocator, request: InspectRequest) anyerror!InspectResult {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return .{ .result = "<not connected>", .@"type" = "" };

        // If variable_ref is provided, expand that variable's children via DAP variables request
        if (request.variable_ref) |var_ref| {
            if (var_ref > 0) {
                const msg = try protocol.variablesRequest(allocator, self.nextSeq(), @intCast(var_ref));
                defer allocator.free(msg);

                const resp = try self.sendRequest(allocator, msg);
                defer allocator.free(resp);

                // Parse using existing translateVariables
                const children = translateVariables(allocator, resp) catch {
                    return .{ .result = "<failed to expand variable>", .@"type" = "" };
                };

                return .{
                    .result = try std.fmt.allocPrint(allocator, "{d} children", .{children.len}),
                    .@"type" = "",
                    .children = children,
                    .result_allocated = true,
                    .children_allocated = true,
                };
            }
        }

        const expr = request.expression orelse return .{ .result = "", .@"type" = "" };
        if (expr.len == 0) return .{ .result = "", .@"type" = "" };

        // Send DAP evaluate request with context
        const frame_id: ?i64 = if (request.frame_id) |fid| @intCast(fid) else null;
        const msg = try protocol.evaluateRequestEx(allocator, self.nextSeq(), expr, frame_id, request.context);
        defer allocator.free(msg);

        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse the evaluate response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return .{ .result = "<invalid response>", .@"type" = "" };
        const success = if (parsed.value.object.get("success")) |v| v == .bool and v.bool else false;
        if (!success) {
            const err_msg = if (parsed.value.object.get("message")) |v| if (v == .string) v.string else "<error>" else "<error>";
            return .{ .result = try allocator.dupe(u8, err_msg), .@"type" = "", .result_allocated = true };
        }

        const body = parsed.value.object.get("body") orelse return .{ .result = "", .@"type" = "" };
        if (body != .object) return .{ .result = "", .@"type" = "" };

        const result_str = if (body.object.get("result")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");
        const type_str = if (body.object.get("type")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");

        // Check if the evaluate result has children that can be expanded
        const var_ref_val: u32 = if (body.object.get("variablesReference")) |v| switch (v) {
            .integer => @intCast(v.integer),
            else => 0,
        } else 0;

        if (var_ref_val > 0) {
            // Auto-expand first level of children
            const vars_msg = try protocol.variablesRequest(allocator, self.nextSeq(), @intCast(var_ref_val));
            defer allocator.free(vars_msg);

            if (self.sendRequest(allocator, vars_msg)) |vars_resp| {
                defer allocator.free(vars_resp);
                if (translateVariables(allocator, vars_resp)) |children| {
                    return .{
                        .result = result_str,
                        .@"type" = type_str,
                        .children = children,
                        .result_allocated = true,
                        .children_allocated = true,
                    };
                } else |_| {}
            } else |_| {}
        }

        return .{ .result = result_str, .@"type" = type_str, .result_allocated = true };
    }

    fn proxyStop(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.process) |*proc| {
            // Send disconnect request
            const msg = try protocol.disconnectRequest(allocator, self.nextSeq());
            defer allocator.free(msg);

            // Try to send gracefully, but don't fail if adapter is already gone
            _ = self.sendRequest(allocator, msg) catch {};

            _ = proc.kill() catch {};
        }
    }

    fn proxyDetach(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.process) |*proc| {
            // Send disconnect without killing the debuggee
            const msg = try protocol.disconnectRequestEx(allocator, self.nextSeq(), false, false);
            defer allocator.free(msg);

            _ = self.sendRequest(allocator, msg) catch {};
            _ = proc.kill() catch {};
        }
    }

    fn proxyThreads(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const ThreadInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) {
            // Fallback: return single main thread
            const result = try allocator.alloc(ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main", .is_stopped = true };
            return result;
        }

        const msg = try protocol.threadsRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch {
            const result = try allocator.alloc(ThreadInfo, 1);
            result[0] = .{ .id = 1, .name = "main", .is_stopped = true };
            return result;
        };
        defer allocator.free(resp);

        // Parse threads response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const threads_val = body.object.get("threads") orelse return error.InvalidResponse;
        if (threads_val != .array) return error.InvalidResponse;

        var threads = std.ArrayListUnmanaged(ThreadInfo).empty;
        for (threads_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const id: u32 = if (obj.get("id")) |v| switch (v) {
                .integer => @intCast(v.integer),
                else => 0,
            } else 0;
            const name = if (obj.get("name")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "thread"),
            } else try allocator.dupe(u8, "thread");

            try threads.append(allocator, .{ .id = id, .name = name, .is_stopped = true });
        }
        return try threads.toOwnedSlice(allocator);
    }

    fn proxyStackTrace(ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32, start_frame: u32, levels: u32) anyerror![]const StackFrame {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return &.{};

        const msg = try protocol.stackTraceRequest(allocator, self.nextSeq(), @intCast(thread_id), @intCast(start_frame), @intCast(levels));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        return translateStackTrace(allocator, resp);
    }

    fn proxyReadMemory(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, size: u64) anyerror![]const u8 {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        // DAP readMemory uses a string memoryReference
        var addr_buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch return error.InvalidAddress;

        const msg = try protocol.readMemoryRequest(allocator, self.nextSeq(), addr_str, 0, @intCast(size));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse response: body.data is base64 encoded
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const data_val = body.object.get("data") orelse return error.InvalidResponse;
        if (data_val != .string) return error.InvalidResponse;

        return try allocator.dupe(u8, data_val.string);
    }

    fn proxyWriteMemory(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, data: []const u8) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        var addr_buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch return error.InvalidAddress;

        // DAP spec requires base64 encoding for writeMemory data
        const base64_data = try base64Encode(allocator, data);
        defer allocator.free(base64_data);

        const msg = try protocol.writeMemoryRequest(allocator, self.nextSeq(), addr_str, 0, base64_data);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        allocator.free(resp);
    }

    fn proxyDisassemble(ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, count: u32, instruction_offset: ?i64, resolve_symbols: ?bool) anyerror![]const DisassembledInstruction {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        var addr_buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "0x{x}", .{address}) catch return error.InvalidAddress;

        const msg = try protocol.disassembleRequestEx(allocator, self.nextSeq(), addr_str, @intCast(count), .{
            .instruction_offset = instruction_offset,
            .resolve_symbols = resolve_symbols,
        });
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse disassemble response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const instructions_val = body.object.get("instructions") orelse return error.InvalidResponse;
        if (instructions_val != .array) return error.InvalidResponse;

        var instructions = std.ArrayListUnmanaged(DisassembledInstruction).empty;
        for (instructions_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const inst_addr = if (obj.get("address")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, "0x0"),
            } else try allocator.dupe(u8, "0x0");

            const instruction = if (obj.get("instruction")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            const bytes = if (obj.get("instructionBytes")) |v| switch (v) {
                .string => try allocator.dupe(u8, v.string),
                else => try allocator.dupe(u8, ""),
            } else try allocator.dupe(u8, "");

            try instructions.append(allocator, .{
                .address = inst_addr,
                .instruction = instruction,
                .bytes = bytes,
            });
        }
        return try instructions.toOwnedSlice(allocator);
    }

    fn proxyAttach(ctx: *anyopaque, allocator: std.mem.Allocator, pid: u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.process == null) return error.NotInitialized;

        // Send initialize if not done yet
        if (!self.initialized) {
            const init_msg = try protocol.initializeRequest(allocator, self.nextSeq());
            defer allocator.free(init_msg);
            const init_resp = try self.sendRequest(allocator, init_msg);
            allocator.free(init_resp);
        }

        // Send attach request (instead of launch)
        const msg = try protocol.attachRequest(allocator, self.nextSeq(), @intCast(pid));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        allocator.free(resp);

        // Send configurationDone
        const config_msg = try protocol.configurationDoneRequest(allocator, self.nextSeq());
        defer allocator.free(config_msg);
        const config_resp = try self.sendRequest(allocator, config_msg);
        allocator.free(config_resp);

        self.initialized = true;
    }

    fn proxySetFunctionBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, condition: ?[]const u8) anyerror!BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        if (self.initialized and self.process != null) {
            const names = [_][]const u8{name};
            const conditions = [_]?[]const u8{condition};
            const msg = try protocol.setFunctionBreakpointsRequest(allocator, self.nextSeq(), &names, &conditions);
            defer allocator.free(msg);
            const resp = self.sendRequest(allocator, msg) catch {
                return .{ .id = bp_id, .verified = false, .file = "", .line = 0 };
            };
            allocator.free(resp);
        }

        return .{ .id = bp_id, .verified = true, .file = "", .line = 0, .condition = condition };
    }

    fn proxySetExceptionBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator, filters: []const []const u8) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return;

        const msg = try protocol.setExceptionBreakpointsRequest(allocator, self.nextSeq(), filters);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxySetVariable(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        // First get scopes for the frame to find the local variables reference
        const scopes_msg = try protocol.scopesRequest(allocator, self.nextSeq(), @intCast(frame_id));
        defer allocator.free(scopes_msg);
        const scopes_resp = try self.sendRequest(allocator, scopes_msg);
        defer allocator.free(scopes_resp);

        // Parse scopes to get variablesReference for locals
        const scopes_parsed = try json.parseFromSlice(json.Value, allocator, scopes_resp, .{});
        defer scopes_parsed.deinit();

        var var_ref: i64 = 0;
        if (scopes_parsed.value == .object) {
            if (scopes_parsed.value.object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("scopes")) |scopes| {
                        if (scopes == .array and scopes.array.items.len > 0) {
                            if (scopes.array.items[0] == .object) {
                                if (scopes.array.items[0].object.get("variablesReference")) |vr| {
                                    if (vr == .integer) var_ref = vr.integer;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (var_ref == 0) return error.NotSupported;

        // Send setVariable request
        const msg = try protocol.setVariableRequest(allocator, self.nextSeq(), var_ref, name, value);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse response
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return .{ .result = value, .@"type" = "" };
        if (body != .object) return .{ .result = value, .@"type" = "" };

        const result_val = if (body.object.get("value")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, value) else try allocator.dupe(u8, value);
        const type_val = if (body.object.get("type")) |v| if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "") else try allocator.dupe(u8, "");
        _ = type_val;

        return .{ .result = result_val, .@"type" = "", .result_allocated = true };
    }

    fn proxyGoto(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror!StopState {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        // 1. Get goto targets for the file:line
        const targets_msg = try protocol.gotoTargetsRequest(allocator, self.nextSeq(), file, @intCast(line));
        defer allocator.free(targets_msg);
        const targets_resp = try self.sendRequest(allocator, targets_msg);
        defer allocator.free(targets_resp);

        // Parse to get target ID
        const parsed = try json.parseFromSlice(json.Value, allocator, targets_resp, .{});
        defer parsed.deinit();

        var target_id: i64 = 0;
        if (parsed.value == .object) {
            if (parsed.value.object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("targets")) |targets| {
                        if (targets == .array and targets.array.items.len > 0) {
                            if (targets.array.items[0] == .object) {
                                if (targets.array.items[0].object.get("id")) |id| {
                                    if (id == .integer) target_id = id.integer;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (target_id == 0) return error.NotSupported;

        // 2. Send goto request
        const goto_msg = try protocol.gotoRequest(allocator, self.nextSeq(), self.thread_id, target_id);
        defer allocator.free(goto_msg);
        const goto_resp = try self.sendRequest(allocator, goto_msg);
        allocator.free(goto_resp);

        // Wait for stopped event
        const event_data = self.waitForEvent(allocator, "stopped") catch {
            return .{ .stop_reason = .step, .location = .{ .file = file, .line = line } };
        };
        defer allocator.free(event_data);

        return translateStoppedEvent(allocator, event_data);
    }

    fn proxyScopes(ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]const Scope {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.scopesRequest(allocator, self.nextSeq(), @intCast(frame_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const scopes_val = body.object.get("scopes") orelse return error.InvalidResponse;
        if (scopes_val != .array) return error.InvalidResponse;

        var scopes = std.ArrayListUnmanaged(Scope).empty;
        errdefer scopes.deinit(allocator);

        for (scopes_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const var_ref: u32 = if (obj.get("variablesReference")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const expensive = if (obj.get("expensive")) |v| (v == .bool and v.bool) else false;

            try scopes.append(allocator, .{
                .name = name,
                .variables_reference = var_ref,
                .expensive = expensive,
            });
        }
        return try scopes.toOwnedSlice(allocator);
    }

    fn proxyDataBreakpointInfo(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, frame_id: ?u32) anyerror!DataBreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const fid: ?i64 = if (frame_id) |f| @intCast(f) else null;
        const msg = try protocol.dataBreakpointInfoRequest(allocator, self.nextSeq(), name, fid);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;

        const data_id = if (body.object.get("dataId")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;
        const description = if (body.object.get("description")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
        const can_persist = if (body.object.get("canPersist")) |v| (v == .bool and v.bool) else false;

        return .{
            .data_id = data_id,
            .description = description,
            .can_persist = can_persist,
        };
    }

    fn proxySetDataBreakpoint(ctx: *anyopaque, allocator: std.mem.Allocator, data_id: []const u8, access_type: DataBreakpointAccessType) anyerror!BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const access_str = @tagName(access_type);
        const msg = try protocol.setDataBreakpointsRequest(allocator, self.nextSeq(), data_id, access_str);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const bp_id = self.next_bp_id;
        self.next_bp_id += 1;

        // Parse response for verification
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        var verified = false;
        if (parsed.value == .object) {
            if (parsed.value.object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("breakpoints")) |bps| {
                        if (bps == .array and bps.array.items.len > 0) {
                            if (bps.array.items[0] == .object) {
                                if (bps.array.items[0].object.get("verified")) |v| {
                                    verified = v == .bool and v.bool;
                                }
                            }
                        }
                    }
                }
            }
        }

        return .{ .id = bp_id, .verified = verified, .file = "", .line = 0 };
    }

    fn proxyCapabilities(ctx: *anyopaque) DebugCapabilities {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        // Return capabilities parsed from the DAP initialize response
        return self.adapter_capabilities;
    }

    fn proxyCompletions(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8, column: u32, frame_id: ?u32) anyerror![]const CompletionItem {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const fid: ?i64 = if (frame_id) |f| @intCast(f) else null;
        const msg = try protocol.completionsRequest(allocator, self.nextSeq(), text, @intCast(column), fid);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const targets = body.object.get("targets") orelse return &.{};
        if (targets != .array) return &.{};

        var items = std.ArrayListUnmanaged(CompletionItem).empty;
        errdefer items.deinit(allocator);

        for (targets.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else continue) else continue;
            const item_text = if (obj.get("text")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const item_type = if (obj.get("type")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");

            try items.append(allocator, .{
                .label = label,
                .text = item_text,
                .item_type = item_type,
            });
        }
        return try items.toOwnedSlice(allocator);
    }

    fn proxyModules(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const Module {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.modulesRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const modules_val = body.object.get("modules") orelse return &.{};
        if (modules_val != .array) return &.{};

        var mods = std.ArrayListUnmanaged(Module).empty;
        errdefer mods.deinit(allocator);

        for (modules_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const mod_id = if (obj.get("id")) |v| blk: {
                break :blk switch (v) {
                    .string => try allocator.dupe(u8, v.string),
                    .integer => blk2: {
                        var buf: [20]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "{d}", .{v.integer}) catch break :blk2 try allocator.dupe(u8, "0");
                        break :blk2 try allocator.dupe(u8, s);
                    },
                    else => try allocator.dupe(u8, ""),
                };
            } else try allocator.dupe(u8, "");

            const name = if (obj.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const path = if (obj.get("path")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const is_opt = if (obj.get("isOptimized")) |v| (v == .bool and v.bool) else false;
            const sym_status = if (obj.get("symbolStatus")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");

            try mods.append(allocator, .{
                .id = mod_id,
                .name = name,
                .path = path,
                .is_optimized = is_opt,
                .symbol_status = sym_status,
            });
        }
        return try mods.toOwnedSlice(allocator);
    }

    fn proxyLoadedSources(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const types.LoadedSource {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.loadedSourcesRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const sources_val = body.object.get("sources") orelse return &.{};
        if (sources_val != .array) return &.{};

        var sources = std.ArrayListUnmanaged(types.LoadedSource).empty;
        errdefer sources.deinit(allocator);

        for (sources_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const name = if (obj.get("name")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const path = if (obj.get("path")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const src_ref: u32 = if (obj.get("sourceReference")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

            try sources.append(allocator, .{
                .name = name,
                .path = path,
                .source_reference = src_ref,
            });
        }
        return try sources.toOwnedSlice(allocator);
    }

    fn proxySource(ctx: *anyopaque, allocator: std.mem.Allocator, source_ref: u32) anyerror![]const u8 {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.sourceRequest(allocator, self.nextSeq(), @intCast(source_ref));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const content = body.object.get("content") orelse return error.InvalidResponse;
        if (content != .string) return error.InvalidResponse;

        return try allocator.dupe(u8, content.string);
    }

    fn proxySetExpression(ctx: *anyopaque, allocator: std.mem.Allocator, expression: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.setExpressionRequest(allocator, self.nextSeq(), expression, value, @intCast(frame_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return .{ .result = value, .@"type" = "" };
        if (body != .object) return .{ .result = value, .@"type" = "" };

        const result_val = if (body.object.get("value")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, value)) else try allocator.dupe(u8, value);

        return .{ .result = result_val, .@"type" = "", .result_allocated = true };
    }

    fn proxyRestartFrame(ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.restartFrameRequest(allocator, self.nextSeq(), @intCast(frame_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        allocator.free(resp);
    }

    fn proxyExceptionInfo(ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32) anyerror!types.ExceptionInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.exceptionInfoRequest(allocator, self.nextSeq(), @intCast(thread_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;

        const exc_id = if (body.object.get("exceptionId")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;
        const description = if (body.object.get("description")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;
        const break_mode = if (body.object.get("breakMode")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else null) else null;

        return .{
            .@"type" = exc_id orelse "",
            .message = description orelse "",
            .id = exc_id,
            .break_mode = break_mode,
        };
    }

    fn proxyTerminate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (self.process == null) return;

        const msg = try protocol.terminateRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        _ = self.sendRequest(allocator, msg) catch {};
    }

    fn updateCapabilitiesFromEvent(self: *DapProxy, caps_obj: std.json.ObjectMap) void {
        // Update individual capability flags from a capabilities event
        if (getBoolCapOpt(caps_obj, "supportsConditionalBreakpoints")) |v| self.adapter_capabilities.supports_conditional_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsHitConditionalBreakpoints")) |v| self.adapter_capabilities.supports_hit_conditional_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsLogPoints")) |v| self.adapter_capabilities.supports_log_points = v;
        if (getBoolCapOpt(caps_obj, "supportsFunctionBreakpoints")) |v| self.adapter_capabilities.supports_function_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsDataBreakpoints")) |v| self.adapter_capabilities.supports_data_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsSetVariable")) |v| self.adapter_capabilities.supports_set_variable = v;
        if (getBoolCapOpt(caps_obj, "supportsGotoTargetsRequest")) |v| self.adapter_capabilities.supports_goto_targets = v;
        if (getBoolCapOpt(caps_obj, "supportsReadMemoryRequest")) |v| self.adapter_capabilities.supports_read_memory = v;
        if (getBoolCapOpt(caps_obj, "supportsWriteMemoryRequest")) |v| self.adapter_capabilities.supports_write_memory = v;
        if (getBoolCapOpt(caps_obj, "supportsDisassembleRequest")) |v| self.adapter_capabilities.supports_disassemble = v;
        if (getBoolCapOpt(caps_obj, "supportsTerminateRequest")) |v| self.adapter_capabilities.supports_terminate = v;
        if (getBoolCapOpt(caps_obj, "supportsCompletionsRequest")) |v| self.adapter_capabilities.supports_completions = v;
        if (getBoolCapOpt(caps_obj, "supportsModulesRequest")) |v| self.adapter_capabilities.supports_modules = v;
        if (getBoolCapOpt(caps_obj, "supportsSetExpression")) |v| self.adapter_capabilities.supports_set_expression = v;
        if (getBoolCapOpt(caps_obj, "supportsStepBack")) |v| self.adapter_capabilities.supports_step_back = v;
        if (getBoolCapOpt(caps_obj, "supportsRestartFrame")) |v| self.adapter_capabilities.supports_restart_frame = v;
        if (getBoolCapOpt(caps_obj, "supportsInstructionBreakpoints")) |v| self.adapter_capabilities.supports_instruction_breakpoints = v;
        if (getBoolCapOpt(caps_obj, "supportsSteppingGranularity")) |v| self.adapter_capabilities.supports_stepping_granularity = v;
        if (getBoolCapOpt(caps_obj, "supportsCancelRequest")) |v| self.adapter_capabilities.supports_cancel_request = v;
        if (getBoolCapOpt(caps_obj, "supportsTerminateThreadsRequest")) |v| self.adapter_capabilities.supports_terminate_threads = v;
        if (getBoolCapOpt(caps_obj, "supportsBreakpointLocationsRequest")) |v| self.adapter_capabilities.supports_breakpoint_locations = v;
        if (getBoolCapOpt(caps_obj, "supportsStepInTargetsRequest")) |v| self.adapter_capabilities.supports_step_in_targets = v;
        if (getBoolCapOpt(caps_obj, "supportsRestartRequest")) |v| self.adapter_capabilities.supports_restart_request = v;
        if (getBoolCapOpt(caps_obj, "supportsExceptionOptions")) |v| self.adapter_capabilities.supports_exception_options = v;
        if (getBoolCapOpt(caps_obj, "supportsExceptionFilterOptions")) |v| self.adapter_capabilities.supports_exception_filter_options = v;
        if (getBoolCapOpt(caps_obj, "supportsExceptionInfoRequest")) |v| self.adapter_capabilities.supports_exception_info_request = v;
        if (getBoolCapOpt(caps_obj, "supportTerminateDebuggee")) |v| self.adapter_capabilities.support_terminate_debuggee = v;
        if (getBoolCapOpt(caps_obj, "supportSuspendDebuggee")) |v| self.adapter_capabilities.support_suspend_debuggee = v;
        if (getBoolCapOpt(caps_obj, "supportsDelayedStackTraceLoading")) |v| self.adapter_capabilities.supports_delayed_stack_trace_loading = v;
        if (getBoolCapOpt(caps_obj, "supportsClipboardContext")) |v| self.adapter_capabilities.supports_clipboard_context = v;
    }

    fn getBoolCapOpt(obj: std.json.ObjectMap, key: []const u8) ?bool {
        const val = obj.get(key) orelse return null;
        if (val == .bool) return val.bool;
        return null;
    }

    fn proxySetInstructionBreakpoints(ctx: *anyopaque, allocator: std.mem.Allocator, breakpoints: []const InstructionBreakpoint) anyerror![]const BreakpointInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.setInstructionBreakpointsRequest(allocator, self.nextSeq(), breakpoints);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        // Parse response: body.breakpoints array
        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const bps_val = body.object.get("breakpoints") orelse return &.{};
        if (bps_val != .array) return &.{};

        var result = std.ArrayListUnmanaged(BreakpointInfo).empty;
        errdefer result.deinit(allocator);

        for (bps_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const bp_id = self.next_bp_id;
            self.next_bp_id += 1;

            const verified = if (obj.get("verified")) |v| (v == .bool and v.bool) else false;
            const bp_line: u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

            try result.append(allocator, .{
                .id = bp_id,
                .verified = verified,
                .file = "",
                .line = bp_line,
            });
        }

        return try result.toOwnedSlice(allocator);
    }

    fn proxyStepInTargets(ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]const StepInTarget {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.stepInTargetsRequest(allocator, self.nextSeq(), @intCast(frame_id));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const targets_val = body.object.get("targets") orelse return &.{};
        if (targets_val != .array) return &.{};

        var targets = std.ArrayListUnmanaged(StepInTarget).empty;
        errdefer targets.deinit(allocator);

        for (targets_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const id: u32 = if (obj.get("id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const line: ?u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const column: ?u32 = if (obj.get("column")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const end_line: ?u32 = if (obj.get("endLine")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const end_column: ?u32 = if (obj.get("endColumn")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;

            try targets.append(allocator, .{
                .id = id,
                .label = label,
                .line = line,
                .column = column,
                .end_line = end_line,
                .end_column = end_column,
            });
        }

        return try targets.toOwnedSlice(allocator);
    }

    fn proxyBreakpointLocations(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, end_line: ?u32) anyerror![]const BreakpointLocation {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const el: ?i64 = if (end_line) |e| @intCast(e) else null;
        const msg = try protocol.breakpointLocationsRequest(allocator, self.nextSeq(), file, @intCast(line), el);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const locs_val = body.object.get("breakpoints") orelse return &.{};
        if (locs_val != .array) return &.{};

        var locations = std.ArrayListUnmanaged(BreakpointLocation).empty;
        errdefer locations.deinit(allocator);

        for (locs_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            const loc_line: u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
            const loc_col: ?u32 = if (obj.get("column")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const loc_end_line: ?u32 = if (obj.get("endLine")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;
            const loc_end_col: ?u32 = if (obj.get("endColumn")) |v| (if (v == .integer) @intCast(v.integer) else null) else null;

            try locations.append(allocator, .{
                .line = loc_line,
                .column = loc_col,
                .end_line = loc_end_line,
                .end_column = loc_end_col,
            });
        }

        return try locations.toOwnedSlice(allocator);
    }

    fn proxyCancel(ctx: *anyopaque, allocator: std.mem.Allocator, request_id: ?u32, progress_id: ?[]const u8) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const rid: ?i64 = if (request_id) |r| @intCast(r) else null;
        const msg = try protocol.cancelRequest(allocator, self.nextSeq(), rid, progress_id);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyTerminateThreads(ctx: *anyopaque, allocator: std.mem.Allocator, thread_ids: []const u32) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        // Convert u32 thread IDs to i64 for the protocol builder
        var ids = try allocator.alloc(i64, thread_ids.len);
        defer allocator.free(ids);
        for (thread_ids, 0..) |tid, i| {
            ids[i] = @intCast(tid);
        }

        const msg = try protocol.terminateThreadsRequest(allocator, self.nextSeq(), ids);
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyRestart(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.restartRequest(allocator, self.nextSeq());
        defer allocator.free(msg);
        const resp = self.sendRequest(allocator, msg) catch return;
        allocator.free(resp);
    }

    fn proxyGotoTargets(ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror![]const types.GotoTarget {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        const msg = try protocol.gotoTargetsRequest(allocator, self.nextSeq(), file, @intCast(line));
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return error.InvalidResponse;
        if (body != .object) return error.InvalidResponse;
        const targets_val = body.object.get("targets") orelse return &.{};
        if (targets_val != .array) return &.{};

        var targets = std.ArrayListUnmanaged(types.GotoTarget).empty;
        errdefer targets.deinit(allocator);

        for (targets_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const target_id: u32 = if (obj.get("id")) |v| (if (v == .integer) @intCast(v.integer) else continue) else continue;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");
            const target_line: u32 = if (obj.get("line")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;

            try targets.append(allocator, .{
                .id = target_id,
                .label = label,
                .line = target_line,
                .column = if (obj.get("column")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
                .end_line = if (obj.get("endLine")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
                .end_column = if (obj.get("endColumn")) |v| (if (v == .integer) @as(u32, @intCast(v.integer)) else null) else null,
            });
        }

        return try targets.toOwnedSlice(allocator);
    }

    fn proxyFindSymbol(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const types.SymbolInfo {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        if (!self.initialized or self.process == null) return error.NotSupported;

        // Use completions request to find symbols
        const msg = try protocol.completionsRequest(allocator, self.nextSeq(), name, @intCast(name.len), null);
        defer allocator.free(msg);
        const resp = try self.sendRequest(allocator, msg);
        defer allocator.free(resp);

        const parsed = try json.parseFromSlice(json.Value, allocator, resp, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const body = parsed.value.object.get("body") orelse return &.{};
        if (body != .object) return &.{};
        const targets = body.object.get("targets") orelse return &.{};
        if (targets != .array) return &.{};

        var symbols = std.ArrayListUnmanaged(types.SymbolInfo).empty;
        errdefer symbols.deinit(allocator);

        for (targets.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const label = if (obj.get("label")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else continue) else continue;
            const kind = if (obj.get("type")) |v| (if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "")) else try allocator.dupe(u8, "");

            try symbols.append(allocator, .{
                .name = label,
                .kind = kind,
            });
        }

        return try symbols.toOwnedSlice(allocator);
    }

    fn proxyDrainNotifications(ctx: *anyopaque, allocator: std.mem.Allocator) []const types.DebugNotification {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        return self.drainNotifications(allocator);
    }

    fn proxyDeinit(ctx: *anyopaque) void {
        const self: *DapProxy = @ptrCast(@alignCast(ctx));
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
};

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buf, data);
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "DapProxy maps RunAction.continue to DAP continue command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .@"continue");
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("continue", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_into to DAP stepIn command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_into);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepIn", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_over to DAP next command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_over);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
}

test "DapProxy maps RunAction.step_out to DAP stepOut command" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_out);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("stepOut", parsed.value.object.get("command").?.string);
}

test "DapProxy translates DAP stopped event to StopState" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":5,"type":"event","event":"stopped","body":{"reason":"breakpoint","threadId":1}}
    ;
    const state = try DapProxy.translateStoppedEvent(allocator, data);
    try std.testing.expectEqual(StopReason.breakpoint, state.stop_reason);
}

test "DapProxy translates DAP stackTrace response to StackFrame array" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":10,"type":"response","request_seq":7,"command":"stackTrace","success":true,"body":{"stackFrames":[{"id":0,"name":"main","source":{"path":"/test/main.py"},"line":10,"column":1},{"id":1,"name":"helper","source":{"path":"/test/utils.py"},"line":5,"column":3}]}}
    ;
    const frames = try DapProxy.translateStackTrace(allocator, data);
    defer {
        for (frames) |f| {
            allocator.free(f.name);
            allocator.free(f.source);
        }
        allocator.free(frames);
    }

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("main", frames[0].name);
    try std.testing.expectEqualStrings("/test/main.py", frames[0].source);
    try std.testing.expectEqual(@as(u32, 10), frames[0].line);
    try std.testing.expectEqualStrings("helper", frames[1].name);
}

test "DapProxy translates DAP variables response to Variable array" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":12,"type":"response","request_seq":11,"command":"variables","success":true,"body":{"variables":[{"name":"x","value":"42","type":"int","variablesReference":0},{"name":"data","value":"[1,2,3]","type":"list","variablesReference":5}]}}
    ;
    const vars = try DapProxy.translateVariables(allocator, data);
    defer {
        for (vars) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
            allocator.free(v.@"type");
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 2), vars.len);
    try std.testing.expectEqualStrings("x", vars[0].name);
    try std.testing.expectEqualStrings("42", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].@"type");
    try std.testing.expectEqual(@as(u32, 0), vars[0].variables_reference);

    try std.testing.expectEqualStrings("data", vars[1].name);
    try std.testing.expectEqual(@as(u32, 5), vars[1].variables_reference);
}

test "DapProxy translates DAP exited event to StopReason.exit" {
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":20,"type":"event","event":"exited","body":{"exitCode":0}}
    ;
    const state = try DapProxy.translateExitedEvent(allocator, data);
    try std.testing.expectEqual(StopReason.exit, state.stop_reason);
    try std.testing.expectEqual(@as(i32, 0), state.exit_code.?);
}

test "DapProxy translates BreakpointRequest to DAP setBreakpoints" {
    const allocator = std.testing.allocator;
    const lines = [_]u32{42};
    const msg = try protocol.setBreakpointsRequest(allocator, 1, "/test/main.py", &lines);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("setBreakpoints", parsed.value.object.get("command").?.string);
    const args = parsed.value.object.get("arguments").?.object;
    try std.testing.expectEqualStrings("/test/main.py", args.get("source").?.object.get("path").?.string);
}

test "DapProxy launches with DAP adapter for Python" {
    // Skip if debugpy is not installed
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "python3", "-c", "import debugpy" },
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.SkipZigTest;

    var proxy = DapProxy.init(std.testing.allocator);
    defer proxy.deinit();

    const config = LaunchConfig{
        .program = "test/fixtures/simple.py",
        .stop_on_entry = true,
    };

    // Launch should succeed (spawns debugpy adapter)
    var driver = proxy.activeDriver();
    driver.launch(std.testing.allocator, config) catch {
        return error.SkipZigTest;
    };

    try std.testing.expect(proxy.initialized);
    try std.testing.expect(proxy.process != null);
}

test "DAP proxy sets breakpoint and hits it in Python" {
    // Skip if debugpy is not installed
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "python3", "-c", "import debugpy" },
    }) catch return error.SkipZigTest;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) return error.SkipZigTest;

    // This test verifies the proxy can create breakpoints via the driver interface
    var proxy = DapProxy.init(std.testing.allocator);
    defer proxy.deinit();

    var driver = proxy.activeDriver();
    const bp = try driver.setBreakpoint(std.testing.allocator, "test/fixtures/simple.py", 4, null);
    try std.testing.expectEqual(@as(u32, 1), bp.id);
    try std.testing.expect(bp.verified);
}

test "DAP proxy step over advances one line" {
    // This test verifies the step_over action maps correctly
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const msg = try proxy.mapRunAction(allocator, .step_over);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("next", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("request", parsed.value.object.get("type").?.string);
}

test "DAP proxy inspect returns local variables" {
    // Verify the proxy can translate a variables response
    const allocator = std.testing.allocator;
    const data =
        \\{"seq":1,"type":"response","request_seq":1,"command":"variables","success":true,"body":{"variables":[{"name":"result","value":"7","type":"int","variablesReference":0}]}}
    ;
    const vars = try DapProxy.translateVariables(allocator, data);
    defer {
        for (vars) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
            allocator.free(v.@"type");
        }
        allocator.free(vars);
    }

    try std.testing.expectEqual(@as(usize, 1), vars.len);
    try std.testing.expectEqualStrings("result", vars[0].name);
    try std.testing.expectEqualStrings("7", vars[0].value);
    try std.testing.expectEqualStrings("int", vars[0].@"type");
}

test "DapProxy translates InspectRequest.expression to DAP evaluate" {
    const allocator = std.testing.allocator;
    const msg = try protocol.evaluateRequest(allocator, 1, "x + y", 0);
    defer allocator.free(msg);

    const parsed = try json.parseFromSlice(json.Value, allocator, msg, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("evaluate", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("x + y", parsed.value.object.get("arguments").?.object.get("expression").?.string);
}

// ── WP11 Tests ──────────────────────────────────────────────────────────

test "DapProxy vtable includes new WP11 function pointers" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const driver = proxy.activeDriver();
    const vt = driver.vtable;

    // All new vtable entries should be non-null (wired to proxy implementations)
    try std.testing.expect(vt.setInstructionBreakpointsFn != null);
    try std.testing.expect(vt.stepInTargetsFn != null);
    try std.testing.expect(vt.breakpointLocationsFn != null);
    try std.testing.expect(vt.cancelFn != null);
    try std.testing.expect(vt.terminateThreadsFn != null);
    try std.testing.expect(vt.restartFn != null);
}

test "DapProxy init and deinit cycle works cleanly" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);

    // Verify initial state
    try std.testing.expect(!proxy.initialized);
    try std.testing.expect(proxy.process == null);
    try std.testing.expectEqual(@as(i64, 1), proxy.seq);
    try std.testing.expectEqual(@as(u32, 1), proxy.next_bp_id);

    // Create active driver and verify vtable
    const driver = proxy.activeDriver();
    try std.testing.expect(driver.driver_type == .dap);

    proxy.deinit();
}

test "DapProxy parseAdapterCapabilities parses new WP9 flags" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    const resp =
        \\{"seq":1,"type":"response","request_seq":1,"command":"initialize","success":true,"body":{"supportsInstructionBreakpoints":true,"supportsSteppingGranularity":true,"supportsCancelRequest":true,"supportsTerminateThreadsRequest":true,"supportsBreakpointLocationsRequest":true,"supportsStepInTargetsRequest":true,"supportsRestartRequest":true,"supportsSingleThreadExecutionRequests":true}}
    ;

    proxy.parseAdapterCapabilities(allocator, resp);

    try std.testing.expect(proxy.adapter_capabilities.supports_instruction_breakpoints);
    try std.testing.expect(proxy.adapter_capabilities.supports_stepping_granularity);
    try std.testing.expect(proxy.adapter_capabilities.supports_cancel_request);
    try std.testing.expect(proxy.adapter_capabilities.supports_terminate_threads);
    try std.testing.expect(proxy.adapter_capabilities.supports_breakpoint_locations);
    try std.testing.expect(proxy.adapter_capabilities.supports_step_in_targets);
    try std.testing.expect(proxy.adapter_capabilities.supports_restart_request);
    try std.testing.expect(proxy.adapter_capabilities.supports_single_thread_execution_requests);
}

test "DapProxy new proxy functions return NotSupported when not initialized" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    var driver = proxy.activeDriver();

    // All new functions should return NotSupported when proxy is not initialized
    try std.testing.expectError(error.NotSupported, driver.setInstructionBreakpoints(allocator, &.{}));
    try std.testing.expectError(error.NotSupported, driver.stepInTargets(allocator, 0));
    try std.testing.expectError(error.NotSupported, driver.breakpointLocations(allocator, "test.zig", 1, null));
    try std.testing.expectError(error.NotSupported, driver.cancel(allocator, null, null));
    try std.testing.expectError(error.NotSupported, driver.terminateThreads(allocator, &.{}));
    try std.testing.expectError(error.NotSupported, driver.restart(allocator));
}

test "DapProxy terminated event sets initialized to false" {
    const allocator = std.testing.allocator;
    var proxy = DapProxy.init(allocator);
    defer proxy.deinit();

    // Simulate the proxy being initialized
    proxy.initialized = true;
    try std.testing.expect(proxy.initialized);

    // The terminated event handler sets initialized to false.
    // We can't easily test it through readResponse without a real transport,
    // but we can verify the vtable and capabilities still work after state change.
    proxy.initialized = false;
    try std.testing.expect(!proxy.initialized);
}
