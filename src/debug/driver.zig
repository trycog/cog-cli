const std = @import("std");
const types = @import("types.zig");

const StopState = types.StopState;
const RunAction = types.RunAction;
const RunOptions = types.RunOptions;
const LaunchConfig = types.LaunchConfig;
const BreakpointInfo = types.BreakpointInfo;
const InspectRequest = types.InspectRequest;
const InspectResult = types.InspectResult;
const ThreadInfo = types.ThreadInfo;
const StackFrame = types.StackFrame;
const DisassembledInstruction = types.DisassembledInstruction;
const Scope = types.Scope;
const DataBreakpointInfo = types.DataBreakpointInfo;
const DataBreakpointAccessType = types.DataBreakpointAccessType;
const DebugCapabilities = types.DebugCapabilities;
const CompletionItem = types.CompletionItem;
const Module = types.Module;
const LoadedSource = types.LoadedSource;
const InstructionBreakpoint = types.InstructionBreakpoint;
const BreakpointLocation = types.BreakpointLocation;
const StepInTarget = types.StepInTarget;

/// Interface that all debug drivers must implement.
/// Both DwarfEngine and DapProxy provide these methods.
pub const DriverVTable = struct {
    launchFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, config: LaunchConfig) anyerror!void,
    runFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, action: RunAction, options: RunOptions) anyerror!StopState,
    setBreakpointFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8, log_message: ?[]const u8) anyerror!BreakpointInfo,
    removeBreakpointFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, id: u32) anyerror!void,
    listBreakpointsFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const BreakpointInfo,
    inspectFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request: InspectRequest) anyerror!InspectResult,
    stopFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
    deinitFn: *const fn (ctx: *anyopaque) void,
    // Phase 3: New vtable functions
    threadsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const ThreadInfo = null,
    stackTraceFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32, start_frame: u32, levels: u32) anyerror![]const StackFrame = null,
    readMemoryFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, size: u64) anyerror![]const u8 = null,
    writeMemoryFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, data: []const u8) anyerror!void = null,
    disassembleFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, address: u64, count: u32, instruction_offset: ?i64, resolve_symbols: ?bool) anyerror![]const DisassembledInstruction = null,
    attachFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, pid: u32) anyerror!void = null,
    // Phase 4: Breakpoint type functions
    setFunctionBreakpointFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, condition: ?[]const u8) anyerror!BreakpointInfo = null,
    setExceptionBreakpointsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, filters: []const []const u8) anyerror!void = null,
    // Phase 4b: Data breakpoints & scopes
    scopesFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]const Scope = null,
    dataBreakpointInfoFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, frame_id: ?u32) anyerror!DataBreakpointInfo = null,
    setDataBreakpointFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, data_id: []const u8, access_type: DataBreakpointAccessType) anyerror!BreakpointInfo = null,
    capabilitiesFn: ?*const fn (ctx: *anyopaque) DebugCapabilities = null,
    // Phase 5: Execution control functions
    setVariableFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult = null,
    gotoFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror!StopState = null,
    // Phase 5b: Completions, modules, source, setExpression, terminate
    completionsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8, column: u32, frame_id: ?u32) anyerror![]const CompletionItem = null,
    modulesFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const Module = null,
    loadedSourcesFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const LoadedSource = null,
    sourceFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, source_ref: u32) anyerror![]const u8 = null,
    setExpressionFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, expression: []const u8, value: []const u8, frame_id: u32) anyerror!InspectResult = null,
    terminateFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
    // Phase 6: Advanced execution control
    restartFrameFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror!void = null,
    // Phase 7: Exception info and registers
    exceptionInfoFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32) anyerror!types.ExceptionInfo = null,
    readRegistersFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32) anyerror![]const types.RegisterInfo = null,
    // Phase 10: Advanced breakpoints, cancel, terminate threads, restart
    setInstructionBreakpointsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, breakpoints: []const InstructionBreakpoint) anyerror![]const BreakpointInfo = null,
    stepInTargetsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]const StepInTarget = null,
    breakpointLocationsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32, end_line: ?u32) anyerror![]const BreakpointLocation = null,
    cancelFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, request_id: ?u32, progress_id: ?[]const u8) anyerror!void = null,
    terminateThreadsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, thread_ids: []const u32) anyerror!void = null,
    restartFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
    detachFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
    gotoTargetsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, file: []const u8, line: u32) anyerror![]const types.GotoTarget = null,
    findSymbolFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]const types.SymbolInfo = null,
    drainNotificationsFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) []const types.DebugNotification = null,
    writeRegistersFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, thread_id: u32, name: []const u8, value: u64) anyerror!void = null,
    variableLocationFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, frame_id: u32) anyerror!types.VariableLocationInfo = null,
    // Core dump loading and DAP passthrough
    loadCoreFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, core_path: []const u8, executable_path: ?[]const u8) anyerror!void = null,
    rawRequestFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8, arguments: ?[]const u8) anyerror![]const u8 = null,
    // Process identification for async safety (kill from main thread)
    getPidFn: ?*const fn (ctx: *anyopaque) ?std.posix.pid_t = null,
};

/// Runtime-polymorphic debug driver.
/// Wraps either a native DWARF engine or a DAP proxy.
pub const ActiveDriver = struct {
    ptr: *anyopaque,
    vtable: *const DriverVTable,
    driver_type: DriverType,

    pub const DriverType = enum {
        native,
        dap,
    };

    pub fn launch(self: *ActiveDriver, allocator: std.mem.Allocator, config: LaunchConfig) !void {
        return self.vtable.launchFn(self.ptr, allocator, config);
    }

    pub fn run(self: *ActiveDriver, allocator: std.mem.Allocator, action: RunAction) !StopState {
        return self.vtable.runFn(self.ptr, allocator, action, .{});
    }

    pub fn runEx(self: *ActiveDriver, allocator: std.mem.Allocator, action: RunAction, options: RunOptions) !StopState {
        return self.vtable.runFn(self.ptr, allocator, action, options);
    }

    pub fn setBreakpoint(self: *ActiveDriver, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8) !BreakpointInfo {
        return self.vtable.setBreakpointFn(self.ptr, allocator, file, line, condition, null, null);
    }

    pub fn setBreakpointEx(self: *ActiveDriver, allocator: std.mem.Allocator, file: []const u8, line: u32, condition: ?[]const u8, hit_condition: ?[]const u8, log_message: ?[]const u8) !BreakpointInfo {
        return self.vtable.setBreakpointFn(self.ptr, allocator, file, line, condition, hit_condition, log_message);
    }

    pub fn removeBreakpoint(self: *ActiveDriver, allocator: std.mem.Allocator, id: u32) !void {
        return self.vtable.removeBreakpointFn(self.ptr, allocator, id);
    }

    pub fn listBreakpoints(self: *ActiveDriver, allocator: std.mem.Allocator) ![]const BreakpointInfo {
        return self.vtable.listBreakpointsFn(self.ptr, allocator);
    }

    pub fn inspect(self: *ActiveDriver, allocator: std.mem.Allocator, request: InspectRequest) !InspectResult {
        return self.vtable.inspectFn(self.ptr, allocator, request);
    }

    pub fn stop(self: *ActiveDriver, allocator: std.mem.Allocator) !void {
        return self.vtable.stopFn(self.ptr, allocator);
    }

    pub fn deinit(self: *ActiveDriver) void {
        self.vtable.deinitFn(self.ptr);
    }

    pub fn threads(self: *ActiveDriver, allocator: std.mem.Allocator) ![]const ThreadInfo {
        const f = self.vtable.threadsFn orelse return error.NotSupported;
        return f(self.ptr, allocator);
    }

    pub fn stackTrace(self: *ActiveDriver, allocator: std.mem.Allocator, thread_id: u32, start_frame: u32, levels: u32) ![]const StackFrame {
        const f = self.vtable.stackTraceFn orelse return error.NotSupported;
        return f(self.ptr, allocator, thread_id, start_frame, levels);
    }

    pub fn readMemory(self: *ActiveDriver, allocator: std.mem.Allocator, address: u64, size: u64) ![]const u8 {
        const f = self.vtable.readMemoryFn orelse return error.NotSupported;
        return f(self.ptr, allocator, address, size);
    }

    pub fn writeMemory(self: *ActiveDriver, allocator: std.mem.Allocator, address: u64, data: []const u8) !void {
        const f = self.vtable.writeMemoryFn orelse return error.NotSupported;
        return f(self.ptr, allocator, address, data);
    }

    pub fn disassemble(self: *ActiveDriver, allocator: std.mem.Allocator, address: u64, count: u32) ![]const DisassembledInstruction {
        const f = self.vtable.disassembleFn orelse return error.NotSupported;
        return f(self.ptr, allocator, address, count, null, null);
    }

    pub fn disassembleEx(self: *ActiveDriver, allocator: std.mem.Allocator, address: u64, count: u32, instruction_offset: ?i64, resolve_symbols: ?bool) ![]const DisassembledInstruction {
        const f = self.vtable.disassembleFn orelse return error.NotSupported;
        return f(self.ptr, allocator, address, count, instruction_offset, resolve_symbols);
    }

    pub fn attach(self: *ActiveDriver, allocator: std.mem.Allocator, pid: u32) !void {
        const f = self.vtable.attachFn orelse return error.NotSupported;
        return f(self.ptr, allocator, pid);
    }

    pub fn setFunctionBreakpoint(self: *ActiveDriver, allocator: std.mem.Allocator, name: []const u8, condition: ?[]const u8) !BreakpointInfo {
        const f = self.vtable.setFunctionBreakpointFn orelse return error.NotSupported;
        return f(self.ptr, allocator, name, condition);
    }

    pub fn setExceptionBreakpoints(self: *ActiveDriver, allocator: std.mem.Allocator, filters: []const []const u8) !void {
        const f = self.vtable.setExceptionBreakpointsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, filters);
    }

    pub fn setVariable(self: *ActiveDriver, allocator: std.mem.Allocator, name: []const u8, value: []const u8, frame_id: u32) !InspectResult {
        const f = self.vtable.setVariableFn orelse return error.NotSupported;
        return f(self.ptr, allocator, name, value, frame_id);
    }

    pub fn goto(self: *ActiveDriver, allocator: std.mem.Allocator, file: []const u8, line: u32) !StopState {
        const f = self.vtable.gotoFn orelse return error.NotSupported;
        return f(self.ptr, allocator, file, line);
    }

    pub fn scopes(self: *ActiveDriver, allocator: std.mem.Allocator, frame_id: u32) ![]const Scope {
        const f = self.vtable.scopesFn orelse return error.NotSupported;
        return f(self.ptr, allocator, frame_id);
    }

    pub fn dataBreakpointInfo(self: *ActiveDriver, allocator: std.mem.Allocator, name: []const u8, frame_id: ?u32) !DataBreakpointInfo {
        const f = self.vtable.dataBreakpointInfoFn orelse return error.NotSupported;
        return f(self.ptr, allocator, name, frame_id);
    }

    pub fn setDataBreakpoint(self: *ActiveDriver, allocator: std.mem.Allocator, data_id: []const u8, access_type: DataBreakpointAccessType) !BreakpointInfo {
        const f = self.vtable.setDataBreakpointFn orelse return error.NotSupported;
        return f(self.ptr, allocator, data_id, access_type);
    }

    pub fn capabilities(self: *ActiveDriver) DebugCapabilities {
        const f = self.vtable.capabilitiesFn orelse return DebugCapabilities{};
        return f(self.ptr);
    }

    pub fn completions(self: *ActiveDriver, allocator: std.mem.Allocator, text: []const u8, column: u32, frame_id: ?u32) ![]const CompletionItem {
        const f = self.vtable.completionsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, text, column, frame_id);
    }

    pub fn modules(self: *ActiveDriver, allocator: std.mem.Allocator) ![]const Module {
        const f = self.vtable.modulesFn orelse return error.NotSupported;
        return f(self.ptr, allocator);
    }

    pub fn loadedSources(self: *ActiveDriver, allocator: std.mem.Allocator) ![]const LoadedSource {
        const f = self.vtable.loadedSourcesFn orelse return error.NotSupported;
        return f(self.ptr, allocator);
    }

    pub fn source(self: *ActiveDriver, allocator: std.mem.Allocator, source_ref: u32) ![]const u8 {
        const f = self.vtable.sourceFn orelse return error.NotSupported;
        return f(self.ptr, allocator, source_ref);
    }

    pub fn setExpression(self: *ActiveDriver, allocator: std.mem.Allocator, expression: []const u8, value: []const u8, frame_id: u32) !InspectResult {
        const f = self.vtable.setExpressionFn orelse return error.NotSupported;
        return f(self.ptr, allocator, expression, value, frame_id);
    }

    pub fn terminate(self: *ActiveDriver, allocator: std.mem.Allocator) !void {
        const f = self.vtable.terminateFn orelse return error.NotSupported;
        return f(self.ptr, allocator);
    }

    pub fn restartFrame(self: *ActiveDriver, allocator: std.mem.Allocator, frame_id: u32) !void {
        const f = self.vtable.restartFrameFn orelse return error.NotSupported;
        return f(self.ptr, allocator, frame_id);
    }

    pub fn exceptionInfo(self: *ActiveDriver, allocator: std.mem.Allocator, thread_id: u32) !types.ExceptionInfo {
        const f = self.vtable.exceptionInfoFn orelse return error.NotSupported;
        return f(self.ptr, allocator, thread_id);
    }

    pub fn readRegisters(self: *ActiveDriver, allocator: std.mem.Allocator, thread_id: u32) ![]const types.RegisterInfo {
        const f = self.vtable.readRegistersFn orelse return error.NotSupported;
        return f(self.ptr, allocator, thread_id);
    }

    pub fn setInstructionBreakpoints(self: *ActiveDriver, allocator: std.mem.Allocator, breakpoints: []const InstructionBreakpoint) ![]const BreakpointInfo {
        const f = self.vtable.setInstructionBreakpointsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, breakpoints);
    }

    pub fn stepInTargets(self: *ActiveDriver, allocator: std.mem.Allocator, frame_id: u32) ![]const StepInTarget {
        const f = self.vtable.stepInTargetsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, frame_id);
    }

    pub fn breakpointLocations(self: *ActiveDriver, allocator: std.mem.Allocator, file: []const u8, line: u32, end_line: ?u32) ![]const BreakpointLocation {
        const f = self.vtable.breakpointLocationsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, file, line, end_line);
    }

    pub fn cancel(self: *ActiveDriver, allocator: std.mem.Allocator, request_id: ?u32, progress_id: ?[]const u8) !void {
        const f = self.vtable.cancelFn orelse return error.NotSupported;
        return f(self.ptr, allocator, request_id, progress_id);
    }

    pub fn terminateThreads(self: *ActiveDriver, allocator: std.mem.Allocator, thread_ids: []const u32) !void {
        const f = self.vtable.terminateThreadsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, thread_ids);
    }

    pub fn restart(self: *ActiveDriver, allocator: std.mem.Allocator) !void {
        const f = self.vtable.restartFn orelse return error.NotSupported;
        return f(self.ptr, allocator);
    }

    pub fn detach(self: *ActiveDriver, allocator: std.mem.Allocator) !void {
        const f = self.vtable.detachFn orelse return error.NotSupported;
        return f(self.ptr, allocator);
    }

    pub fn gotoTargets(self: *ActiveDriver, allocator: std.mem.Allocator, file: []const u8, line: u32) ![]const types.GotoTarget {
        const f = self.vtable.gotoTargetsFn orelse return error.NotSupported;
        return f(self.ptr, allocator, file, line);
    }

    pub fn findSymbol(self: *ActiveDriver, allocator: std.mem.Allocator, name: []const u8) ![]const types.SymbolInfo {
        const f = self.vtable.findSymbolFn orelse return error.NotSupported;
        return f(self.ptr, allocator, name);
    }

    pub fn drainNotifications(self: *ActiveDriver, allocator: std.mem.Allocator) []const types.DebugNotification {
        const f = self.vtable.drainNotificationsFn orelse return &.{};
        return f(self.ptr, allocator);
    }

    pub fn writeRegisters(self: *ActiveDriver, allocator: std.mem.Allocator, thread_id: u32, name: []const u8, value: u64) !void {
        const f = self.vtable.writeRegistersFn orelse return error.NotSupported;
        return f(self.ptr, allocator, thread_id, name, value);
    }

    pub fn variableLocation(self: *ActiveDriver, allocator: std.mem.Allocator, name: []const u8, frame_id: u32) !types.VariableLocationInfo {
        const f = self.vtable.variableLocationFn orelse return error.NotSupported;
        return f(self.ptr, allocator, name, frame_id);
    }

    pub fn loadCore(self: *ActiveDriver, allocator: std.mem.Allocator, core_path: []const u8, executable_path: ?[]const u8) !void {
        const f = self.vtable.loadCoreFn orelse return error.NotSupported;
        return f(self.ptr, allocator, core_path, executable_path);
    }

    pub fn rawRequest(self: *ActiveDriver, allocator: std.mem.Allocator, command: []const u8, arguments: ?[]const u8) ![]const u8 {
        const f = self.vtable.rawRequestFn orelse return error.NotSupported;
        return f(self.ptr, allocator, command, arguments);
    }

    /// Get the PID of the debuggee (native) or adapter (DAP) process.
    /// Used by toolStop to safely kill the process when a background
    /// run thread is blocking on waitpid/read.
    pub fn getPid(self: *ActiveDriver) ?std.posix.pid_t {
        const f = self.vtable.getPidFn orelse return null;
        return f(self.ptr);
    }
};

// ── Mock Driver for Testing ─────────────────────────────────────────────

pub const MockDriver = struct {
    launched: bool = false,
    stopped: bool = false,
    run_count: u32 = 0,
    breakpoint_count: u32 = 0,

    pub fn activeDriver(self: *MockDriver) ActiveDriver {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
            .driver_type = .dap,
        };
    }

    const vtable = DriverVTable{
        .launchFn = mockLaunch,
        .runFn = mockRun,
        .setBreakpointFn = mockSetBreakpoint,
        .removeBreakpointFn = mockRemoveBreakpoint,
        .listBreakpointsFn = mockListBreakpoints,
        .inspectFn = mockInspect,
        .stopFn = mockStop,
        .deinitFn = mockDeinit,
        .scopesFn = mockScopes,
        .capabilitiesFn = mockCapabilities,
    };

    fn mockLaunch(ctx: *anyopaque, _: std.mem.Allocator, _: LaunchConfig) anyerror!void {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.launched = true;
    }

    fn mockRun(ctx: *anyopaque, _: std.mem.Allocator, _: RunAction, _: RunOptions) anyerror!StopState {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.run_count += 1;
        return .{ .stop_reason = .step };
    }

    fn mockSetBreakpoint(ctx: *anyopaque, _: std.mem.Allocator, file: []const u8, line: u32, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8) anyerror!BreakpointInfo {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.breakpoint_count += 1;
        return .{
            .id = self.breakpoint_count,
            .verified = true,
            .file = file,
            .line = line,
        };
    }

    fn mockRemoveBreakpoint(_: *anyopaque, _: std.mem.Allocator, _: u32) anyerror!void {}

    fn mockListBreakpoints(_: *anyopaque, _: std.mem.Allocator) anyerror![]const BreakpointInfo {
        return &.{};
    }

    fn mockInspect(_: *anyopaque, _: std.mem.Allocator, _: InspectRequest) anyerror!InspectResult {
        return .{ .result = "42", .@"type" = "int" };
    }

    fn mockStop(ctx: *anyopaque, _: std.mem.Allocator) anyerror!void {
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.stopped = true;
    }

    fn mockDeinit(_: *anyopaque) void {}

    fn mockScopes(_: *anyopaque, allocator: std.mem.Allocator, _: u32) anyerror![]const Scope {
        const result = try allocator.alloc(Scope, 1);
        result[0] = .{ .name = "Locals", .variables_reference = 1, .expensive = false };
        return result;
    }

    fn mockCapabilities(_: *anyopaque) DebugCapabilities {
        return .{};
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "MockDriver implements ActiveDriver interface" {
    var mock = MockDriver{};
    var driver = mock.activeDriver();

    try driver.launch(std.testing.allocator, .{ .program = "test" });
    try std.testing.expect(mock.launched);

    const state = try driver.run(std.testing.allocator, .@"continue");
    try std.testing.expectEqual(types.StopReason.step, state.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), mock.run_count);

    const bp = try driver.setBreakpoint(std.testing.allocator, "test.py", 10, null);
    try std.testing.expectEqual(@as(u32, 1), bp.id);
    try std.testing.expect(bp.verified);

    try driver.stop(std.testing.allocator);
    try std.testing.expect(mock.stopped);

    driver.deinit();
}

test "ActiveDriver returns NotSupported for null vtable entries" {
    var mock = MockDriver{};
    var driver = mock.activeDriver();

    // All Phase 10 vtable entries default to null, so they should return error.NotSupported
    try std.testing.expectError(error.NotSupported, driver.setInstructionBreakpoints(std.testing.allocator, &.{}));
    try std.testing.expectError(error.NotSupported, driver.stepInTargets(std.testing.allocator, 0));
    try std.testing.expectError(error.NotSupported, driver.breakpointLocations(std.testing.allocator, "test.zig", 1, null));
    try std.testing.expectError(error.NotSupported, driver.cancel(std.testing.allocator, null, null));
    try std.testing.expectError(error.NotSupported, driver.terminateThreads(std.testing.allocator, &.{}));
    try std.testing.expectError(error.NotSupported, driver.restart(std.testing.allocator));
}
