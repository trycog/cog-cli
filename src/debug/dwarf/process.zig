const std = @import("std");
const builtin = @import("builtin");

pub const process_mach = @import("process_mach.zig");
pub const process_ptrace = @import("process_ptrace.zig");

/// Platform-abstracted process control.
/// Selected at compile time based on the target OS.
pub const ProcessControl = if (builtin.os.tag == .macos)
    process_mach.MachProcessControl
else if (builtin.os.tag == .linux)
    process_ptrace.PtraceProcessControl
else
    UnsupportedProcessControl;

pub const WaitResult = process_mach.WaitResult;
pub const RegisterState = process_mach.RegisterState;
pub const FloatRegisterState = process_mach.FloatRegisterState;

const UnsupportedProcessControl = struct {
    pub fn spawn(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const []const u8) !void {
        return error.UnsupportedPlatform;
    }
    pub fn kill(_: *@This()) !void {}
};

// ── Tests ───────────────────────────────────────────────────────────────

test "ProcessControl selects correct platform implementation" {
    if (builtin.os.tag == .macos) {
        try std.testing.expect(ProcessControl == process_mach.MachProcessControl);
    } else if (builtin.os.tag == .linux) {
        try std.testing.expect(ProcessControl == process_ptrace.PtraceProcessControl);
    }
}

test {
    _ = process_mach;
    _ = process_ptrace;
}
