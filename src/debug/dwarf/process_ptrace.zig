const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const process_mach = @import("process_mach.zig");

// ── Linux ptrace-based Process Control ──────────────────────────────────

const WUNTRACED: u32 = 0x00000002;
const SIGKILL: u8 = 9;

// Linux x86_64 user_regs_struct layout — used with PTRACE_GETREGS / PTRACE_SETREGS.
// Matches the kernel's struct user_regs_struct from <sys/user.h>.
const UserRegsStruct = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    orig_rax: u64,
    rip: u64,
    cs: u64,
    eflags: u64,
    rsp: u64,
    ss: u64,
    fs_base: u64,
    gs_base: u64,
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,
};

pub const PtraceProcessControl = struct {
    pid: ?posix.pid_t = null,
    is_running: bool = false,

    pub fn spawn(self: *PtraceProcessControl, allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        defer argv.deinit(allocator);

        const prog_z = try allocator.dupeZ(u8, program);
        defer allocator.free(prog_z);
        try argv.append(allocator, prog_z.ptr);

        var arg_strs: std.ArrayListUnmanaged([:0]const u8) = .empty;
        defer {
            for (arg_strs.items) |a| allocator.free(a);
            arg_strs.deinit(allocator);
        }
        for (args) |arg| {
            const a = try allocator.dupeZ(u8, arg);
            try arg_strs.append(allocator, a);
            try argv.append(allocator, a.ptr);
        }
        try argv.append(allocator, null);

        const pid = try posix.fork();
        if (pid == 0) {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.TRACEME, 0, 0, 0);
            }
            posix.execvpeZ(prog_z.ptr, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ)) catch {};
            std.posix.exit(127);
        }

        self.pid = pid;
        self.is_running = false;

        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn continueExecution(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.CONT, pid, 0, 0);
            }
            self.is_running = true;
        }
    }

    pub fn singleStep(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.SINGLESTEP, pid, 0, 0);
            }
            self.is_running = true;
        }
    }

    pub fn waitForStop(self: *PtraceProcessControl) !process_mach.WaitResult {
        if (self.pid) |pid| {
            const result = posix.waitpid(pid, WUNTRACED);
            self.is_running = false;

            const status = result.status;
            if ((status & 0x7f) == 0) {
                return .{ .status = .exited, .exit_code = @intCast((status >> 8) & 0xff) };
            }
            if ((status & 0xff) == 0x7f) {
                return .{ .status = .stopped, .signal = @intCast((status >> 8) & 0xff) };
            }
            return .{ .status = .unknown };
        }
        return error.NoProcess;
    }

    /// Read the tracee's general-purpose registers via PTRACE_GETREGS.
    /// Maps x86_64 registers to the platform-independent RegisterState using
    /// the DWARF register numbering: gprs[0]=rax, [1]=rdx, [2]=rcx, [3]=rbx,
    /// [4]=rsi, [5]=rdi, [6]=rbp, [7]=rsp, [8..15]=r8..r15.
    pub fn readRegisters(self: *PtraceProcessControl) !process_mach.RegisterState {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        if (builtin.os.tag == .linux) {
            var regs: UserRegsStruct = undefined;
            const rc = std.os.linux.ptrace(.GETREGS, pid, 0, @intFromPtr(&regs));
            if (rc != 0) return error.PtraceGetRegsFailed;

            var state = process_mach.RegisterState{};
            // DWARF x86_64 register mapping
            state.gprs[0] = regs.rax;
            state.gprs[1] = regs.rdx;
            state.gprs[2] = regs.rcx;
            state.gprs[3] = regs.rbx;
            state.gprs[4] = regs.rsi;
            state.gprs[5] = regs.rdi;
            state.gprs[6] = regs.rbp;
            state.gprs[7] = regs.rsp;
            state.gprs[8] = regs.r8;
            state.gprs[9] = regs.r9;
            state.gprs[10] = regs.r10;
            state.gprs[11] = regs.r11;
            state.gprs[12] = regs.r12;
            state.gprs[13] = regs.r13;
            state.gprs[14] = regs.r14;
            state.gprs[15] = regs.r15;
            state.pc = regs.rip;
            state.sp = regs.rsp;
            state.fp = regs.rbp;
            state.flags = regs.eflags;
            return state;
        }
        unreachable;
    }

    /// Read floating point / SIMD registers from the traced process.
    /// Linux FP register reading via PTRACE_GETREGSET is more complex;
    /// this is a stub that returns empty for now.
    pub fn readFloatRegisters(self: *PtraceProcessControl) !process_mach.FloatRegisterState {
        if (self.pid == null) return error.NoProcess;
        // Linux FP register reading via PTRACE_GETREGSET with NT_PRFPREG
        // is more involved and less critical. Return empty state for now.
        return .{};
    }

    /// Write registers back to the tracee via PTRACE_SETREGS.
    /// Reverses the DWARF register mapping from RegisterState back to
    /// the kernel's user_regs_struct layout.
    pub fn writeRegisters(self: *PtraceProcessControl, regs: process_mach.RegisterState) !void {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        if (builtin.os.tag == .linux) {
            // First read current registers so we preserve fields not in RegisterState
            // (orig_rax, cs, ss, segment bases, etc.)
            var kregs: UserRegsStruct = undefined;
            var rc = std.os.linux.ptrace(.GETREGS, pid, 0, @intFromPtr(&kregs));
            if (rc != 0) return error.PtraceGetRegsFailed;

            // Map RegisterState back to kernel struct
            kregs.rax = regs.gprs[0];
            kregs.rdx = regs.gprs[1];
            kregs.rcx = regs.gprs[2];
            kregs.rbx = regs.gprs[3];
            kregs.rsi = regs.gprs[4];
            kregs.rdi = regs.gprs[5];
            kregs.rbp = regs.gprs[6];
            kregs.rsp = regs.gprs[7];
            kregs.r8 = regs.gprs[8];
            kregs.r9 = regs.gprs[9];
            kregs.r10 = regs.gprs[10];
            kregs.r11 = regs.gprs[11];
            kregs.r12 = regs.gprs[12];
            kregs.r13 = regs.gprs[13];
            kregs.r14 = regs.gprs[14];
            kregs.r15 = regs.gprs[15];
            kregs.rip = regs.pc;
            kregs.rsp = regs.sp;
            kregs.rbp = regs.fp;
            kregs.eflags = regs.flags;

            rc = std.os.linux.ptrace(.SETREGS, pid, 0, @intFromPtr(&kregs));
            if (rc != 0) return error.PtraceSetRegsFailed;
        }
    }

    /// Read memory from the tracee's address space.
    /// First attempts process_vm_readv for efficient bulk reads, then falls
    /// back to PTRACE_PEEKDATA word-by-word if that fails.
    /// Returns raw bytes allocated with the provided allocator (same pattern
    /// as the Mach implementation).
    pub fn readMemory(self: *PtraceProcessControl, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        if (builtin.os.tag == .linux) {
            // Try process_vm_readv first (fast path — single syscall for bulk reads)
            const did_vmreadv = blk: {
                var local_iov = [_]std.posix.iovec{
                    .{ .base = buf.ptr, .len = size },
                };
                var remote_iov = [_]std.posix.iovec{
                    .{ .base = @ptrFromInt(address), .len = size },
                };
                // process_vm_readv syscall number on x86_64 is 310
                const SYS_process_vm_readv = 310;
                const rc = std.os.linux.syscall6(
                    @enumFromInt(SYS_process_vm_readv),
                    @bitCast(@as(isize, @intCast(pid))),
                    @intFromPtr(&local_iov),
                    1, // liovcnt
                    @intFromPtr(&remote_iov),
                    1, // riovcnt
                    0, // flags
                );
                // rc is bytes read (positive) or negative errno
                const signed_rc: isize = @bitCast(rc);
                if (signed_rc >= 0 and @as(usize, @intCast(signed_rc)) == size) {
                    break :blk true;
                }
                break :blk false;
            };

            if (!did_vmreadv) {
                // Fallback: PTRACE_PEEKDATA word-by-word (8 bytes per call on x86_64)
                const word_size = @sizeOf(usize); // 8 on x86_64
                var offset: usize = 0;
                while (offset < size) {
                    const addr = address + offset;
                    const rc = std.os.linux.ptrace(.PEEKDATA, pid, addr, 0);
                    // PEEKDATA returns the word value in the return code
                    const word_bytes = std.mem.asBytes(&rc);
                    const remaining = size - offset;
                    const to_copy = @min(remaining, word_size);
                    @memcpy(buf[offset..][0..to_copy], word_bytes[0..to_copy]);
                    offset += word_size;
                }
            }
        }

        return buf;
    }

    /// Write memory to the tracee's address space via PTRACE_POKEDATA.
    /// Writes word-by-word (8 bytes at a time on x86_64). For partial
    /// words at the end, reads the existing word first, patches the
    /// relevant bytes, and writes back.
    pub fn writeMemory(self: *PtraceProcessControl, address: u64, data: []const u8) !void {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        if (builtin.os.tag == .linux) {
            const word_size = @sizeOf(usize); // 8 on x86_64
            var offset: usize = 0;

            while (offset < data.len) {
                const addr = address + offset;
                const remaining = data.len - offset;

                if (remaining >= word_size) {
                    // Full word write
                    var word: usize = 0;
                    const word_bytes = std.mem.asBytes(&word);
                    @memcpy(word_bytes[0..word_size], data[offset..][0..word_size]);
                    const rc = std.os.linux.ptrace(.POKEDATA, pid, addr, word);
                    const signed_rc: isize = @bitCast(rc);
                    if (signed_rc != 0) return error.PtracePokeDataFailed;
                } else {
                    // Partial word at the end: read-modify-write
                    const existing = std.os.linux.ptrace(.PEEKDATA, pid, addr, 0);
                    var word: usize = @bitCast(existing);
                    const word_bytes = std.mem.asBytes(&word);
                    @memcpy(word_bytes[0..remaining], data[offset..][0..remaining]);
                    const rc = std.os.linux.ptrace(.POKEDATA, pid, addr, word);
                    const signed_rc: isize = @bitCast(rc);
                    if (signed_rc != 0) return error.PtracePokeDataFailed;
                }

                offset += word_size;
            }
        }
    }

    /// Get the text segment base address by parsing /proc/{pid}/maps.
    /// Finds the first executable mapping (permissions contain 'x') and
    /// returns its start address. Used by the engine for ASLR slide calculation.
    pub fn getTextBase(self: *PtraceProcessControl) !u64 {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        if (builtin.os.tag == .linux) {
            // Format: /proc/<pid>/maps
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/maps", .{pid}) catch return error.TextBaseNotFound;

            const file = std.fs.openFileAbsolute(path, .{}) catch return error.TextBaseNotFound;
            defer file.close();

            var buf: [4096]u8 = undefined;
            while (true) {
                const line = file.reader().readUntilDelimiter(&buf, '\n') catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return error.TextBaseNotFound,
                };

                // Format: <start>-<end> <perms> <offset> <dev> <inode> <pathname>
                // Example: 00400000-00452000 r-xp 00000000 08:02 173521 /usr/bin/foo
                // We want the first mapping with execute permission ('x' in perms)
                const dash_pos = std.mem.indexOfScalar(u8, line, '-') orelse continue;
                const after_dash = line[dash_pos + 1 ..];
                const space_pos = std.mem.indexOfScalar(u8, after_dash, ' ') orelse continue;
                const perms_start = space_pos + 1;
                if (perms_start + 4 > after_dash.len) continue;
                const perms = after_dash[perms_start .. perms_start + 4];

                // Check for execute permission (third char is 'x')
                if (perms[2] == 'x') {
                    const start_hex = line[0..dash_pos];
                    const addr = std.fmt.parseUnsigned(u64, start_hex, 16) catch continue;
                    return addr;
                }
            }
            return error.TextBaseNotFound;
        }
        unreachable;
    }

    /// On Linux there is no Mach task port equivalent. Return error so the
    /// engine falls back to its single-thread view.
    pub fn getTask(self: *PtraceProcessControl) !u32 {
        _ = self;
        return error.NotSupported;
    }

    pub fn kill(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            posix.kill(pid, SIGKILL) catch {};
            _ = posix.waitpid(pid, 0);
            self.pid = null;
            self.is_running = false;
        }
    }

    pub fn attach(self: *PtraceProcessControl, pid: posix.pid_t) !void {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.ptrace(.ATTACH, pid, 0, 0);
        }
        self.pid = pid;
        self.is_running = false;
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn detach(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(.DETACH, pid, 0, 0);
            }
            self.pid = null;
            self.is_running = false;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "PtraceProcessControl initial state" {
    const pc = PtraceProcessControl{};
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}

test "PtraceProcessControl getTask returns NotSupported" {
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    try std.testing.expectError(error.NotSupported, pc.getTask());
}

test "PtraceProcessControl readRegisters returns NoProcess when no pid" {
    var pc = PtraceProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.readRegisters());
}

test "PtraceProcessControl readFloatRegisters returns NoProcess when no pid" {
    var pc = PtraceProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.readFloatRegisters());
}

test "PtraceProcessControl readFloatRegisters returns empty on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    const fp = try pc.readFloatRegisters();
    try std.testing.expectEqual(@as(u32, 0), fp.count);
}

test "PtraceProcessControl writeRegisters returns NoProcess when no pid" {
    var pc = PtraceProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.writeRegisters(.{}));
}

test "PtraceProcessControl readMemory returns NoProcess when no pid" {
    var pc = PtraceProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.readMemory(0x1000, 16, std.testing.allocator));
}

test "PtraceProcessControl writeMemory returns NoProcess when no pid" {
    var pc = PtraceProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.writeMemory(0x1000, &.{ 0x90, 0x90 }));
}

test "PtraceProcessControl getTextBase returns NoProcess when no pid" {
    var pc = PtraceProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.getTextBase());
}

test "PtraceProcessControl readRegisters returns UnsupportedPlatform on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    try std.testing.expectError(error.UnsupportedPlatform, pc.readRegisters());
}

test "PtraceProcessControl writeRegisters returns UnsupportedPlatform on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    try std.testing.expectError(error.UnsupportedPlatform, pc.writeRegisters(.{}));
}

test "PtraceProcessControl readMemory returns UnsupportedPlatform on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    try std.testing.expectError(error.UnsupportedPlatform, pc.readMemory(0x1000, 16, std.testing.allocator));
}

test "PtraceProcessControl writeMemory returns UnsupportedPlatform on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    try std.testing.expectError(error.UnsupportedPlatform, pc.writeMemory(0x1000, &.{ 0x90, 0x90 }));
}

test "PtraceProcessControl getTextBase returns UnsupportedPlatform on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.pid = 1;
    try std.testing.expectError(error.UnsupportedPlatform, pc.getTextBase());
}

// Linux-specific integration tests — require a real traced process.
// Run manually with: zig test src/debug/dwarf/process_ptrace.zig --single-threaded
// on a Linux x86_64 system.

test "spawn and readRegisters on Linux" {
    if (builtin.os.tag != .linux or !builtin.single_threaded) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const regs = try pc.readRegisters();
    // After exec stop, rip should be non-zero (pointing at the entry point)
    try std.testing.expect(regs.pc != 0);
    try std.testing.expect(regs.sp != 0);
}

test "spawn and readMemory on Linux" {
    if (builtin.os.tag != .linux or !builtin.single_threaded) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const regs = try pc.readRegisters();
    // Read a few bytes from the instruction pointer (should be valid code)
    const mem = try pc.readMemory(regs.pc, 4, std.testing.allocator);
    defer std.testing.allocator.free(mem);
    try std.testing.expectEqual(@as(usize, 4), mem.len);
}

test "spawn and getTextBase on Linux" {
    if (builtin.os.tag != .linux or !builtin.single_threaded) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const base = try pc.getTextBase();
    // Text base should be non-zero
    try std.testing.expect(base != 0);
}

test "writeMemory and readMemory round-trip on Linux" {
    if (builtin.os.tag != .linux or !builtin.single_threaded) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    // Read the stack pointer and use an address on the stack for round-trip test
    const regs = try pc.readRegisters();
    const test_addr = regs.sp - 64; // below current stack frame
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try pc.writeMemory(test_addr, &test_data);
    const readback = try pc.readMemory(test_addr, 4, std.testing.allocator);
    defer std.testing.allocator.free(readback);
    try std.testing.expectEqualSlices(u8, &test_data, readback);
}

test "writeRegisters round-trip on Linux" {
    if (builtin.os.tag != .linux or !builtin.single_threaded) return error.SkipZigTest;
    var pc = PtraceProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    var regs = try pc.readRegisters();
    const orig_rax = regs.gprs[0];
    regs.gprs[0] = 0x42424242;
    try pc.writeRegisters(regs);
    const regs2 = try pc.readRegisters();
    try std.testing.expectEqual(@as(u64, 0x42424242), regs2.gprs[0]);
    // Restore
    regs.gprs[0] = orig_rax;
    try pc.writeRegisters(regs);
}
