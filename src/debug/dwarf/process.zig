const std = @import("std");
const builtin = @import("builtin");
const process_types = @import("process_types.zig");
const core_dump_mod = @import("core_dump.zig");
const debug_log = @import("../../debug_log.zig");

pub const WaitResult = process_types.WaitResult;
pub const RegisterState = process_types.RegisterState;
pub const FloatRegisterState = process_types.FloatRegisterState;

/// Platform-abstracted process control.
/// Selected at compile time based on the target OS.
pub const ProcessControl = if (builtin.os.tag == .macos)
    @import("process_mach.zig").MachProcessControl
else if (builtin.os.tag == .linux)
    @import("process_ptrace.zig").PtraceProcessControl
else
    UnsupportedProcessControl;

/// Read-only register and memory access backed by either a live process or a core dump.
pub const ProcessOrCoreAccess = struct {
    context: *anyopaque,
    source: Source,
    read_registers_fn: *const fn (context: *anyopaque) anyerror!RegisterState,
    read_memory_fn: *const fn (context: *anyopaque, address: u64, size: usize, allocator: std.mem.Allocator) anyerror![]u8,

    pub const Source = enum {
        process,
        core,
    };

    /// Create read access backed by a live process controller.
    pub fn fromProcess(process: *ProcessControl) ProcessOrCoreAccess {
        debug_log.log("dwarf.access: selected live process access", .{});
        return .{
            .context = @ptrCast(process),
            .source = .process,
            .read_registers_fn = processReadRegisters,
            .read_memory_fn = processReadMemory,
        };
    }

    /// Create read access backed by a parsed core dump.
    pub fn fromCore(core: *core_dump_mod.CoreDump) ProcessOrCoreAccess {
        debug_log.log("dwarf.access: selected core dump access", .{});
        return .{
            .context = @ptrCast(core),
            .source = .core,
            .read_registers_fn = coreReadRegisters,
            .read_memory_fn = coreReadMemory,
        };
    }

    /// Read the current or captured general-purpose registers.
    pub fn readRegisters(self: ProcessOrCoreAccess) !RegisterState {
        debug_log.log("dwarf.access: read registers source={s}", .{@tagName(self.source)});
        return self.read_registers_fn(self.context);
    }

    /// Read target memory from the live process or captured core segments.
    /// The caller owns the returned slice.
    pub fn readMemory(self: ProcessOrCoreAccess, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        debug_log.log("dwarf.access: read memory source={s} address=0x{x} size={d}", .{ @tagName(self.source), address, size });
        return self.read_memory_fn(self.context, address, size, allocator);
    }

    fn processReadRegisters(context: *anyopaque) !RegisterState {
        const process: *ProcessControl = @ptrCast(@alignCast(context));
        return process.readRegisters();
    }

    fn processReadMemory(context: *anyopaque, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        const process: *ProcessControl = @ptrCast(@alignCast(context));
        return process.readMemory(address, size, allocator);
    }

    fn coreReadRegisters(context: *anyopaque) !RegisterState {
        const core: *core_dump_mod.CoreDump = @ptrCast(@alignCast(context));
        return core.readRegisters();
    }

    fn coreReadMemory(context: *anyopaque, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        const core: *core_dump_mod.CoreDump = @ptrCast(@alignCast(context));
        return core.readMemory(address, size, allocator);
    }
};

const UnsupportedProcessControl = struct {
    pub fn spawn(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const []const u8) !void {
        return error.UnsupportedPlatform;
    }
    pub fn kill(_: *@This()) !void {}
};

// ── Tests ───────────────────────────────────────────────────────────────

test "ProcessControl selects correct platform implementation" {
    if (builtin.os.tag == .macos) {
        try std.testing.expect(ProcessControl == @import("process_mach.zig").MachProcessControl);
    } else if (builtin.os.tag == .linux) {
        try std.testing.expect(ProcessControl == @import("process_ptrace.zig").PtraceProcessControl);
    }
}

test "ProcessOrCoreAccess reads synthetic core registers and memory" {
    const allocator = std.testing.allocator;
    const data = try allocator.dupe(u8, "HEADcaptured-stack");
    const segments = try allocator.alloc(core_dump_mod.CoreDump.Segment, 1);
    segments[0] = .{
        .vaddr = 0x7000,
        .file_offset = 4,
        .file_size = 14,
        .mem_size = 14,
    };
    var core = core_dump_mod.CoreDump{
        .data = data,
        .segments = segments,
        .registers = .{ .pc = 0x401020, .sp = 0x7000, .fp = 0x7008 },
        .allocator = allocator,
    };
    defer core.deinit();

    const access = ProcessOrCoreAccess.fromCore(&core);
    const registers = try access.readRegisters();
    try std.testing.expectEqual(@as(u64, 0x401020), registers.pc);

    const memory = try access.readMemory(0x7000, 8, allocator);
    defer allocator.free(memory);
    try std.testing.expectEqualStrings("captured", memory);
}

test {
    if (builtin.os.tag == .macos) {
        _ = @import("process_mach.zig");
    }
    if (builtin.os.tag == .linux) {
        _ = @import("process_ptrace.zig");
    }
    _ = @import("process_types.zig");
}
