const std = @import("std");
const builtin = @import("builtin");
const process_types = @import("process_types.zig");

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

test {
    if (builtin.os.tag == .macos) {
        _ = @import("process_mach.zig");
    }
    if (builtin.os.tag == .linux) {
        _ = @import("process_ptrace.zig");
    }
    _ = @import("process_types.zig");
}
