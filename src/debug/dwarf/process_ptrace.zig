const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const process_types = @import("process_types.zig");
const debug_log = @import("../../debug_log.zig");

// ── Linux ptrace-based Process Control ──────────────────────────────────

const WUNTRACED: u32 = 0x00000002;
const WNOHANG: u32 = 0x00000001;
const SIGKILL: u8 = 9;

/// Poll cadence for bounded waits. Short enough that a pause feels immediate,
/// long enough that waiting costs no measurable CPU.
const wait_poll_interval_ns: u64 = 2 * std.time.ns_per_ms;

const PTRACE_TRACEME: u32 = 0;
const PTRACE_PEEKDATA: u32 = 2;
const PTRACE_POKEDATA: u32 = 5;
const PTRACE_CONT: u32 = 7;
const PTRACE_SINGLESTEP: u32 = 9;
const PTRACE_GETREGS: u32 = 12;
const PTRACE_SETREGS: u32 = 13;
const PTRACE_ATTACH: u32 = 16;
const PTRACE_DETACH: u32 = 17;
const PTRACE_GETREGSET: u32 = 0x4204;
const PTRACE_SETREGSET: u32 = 0x4205;
const NT_PRSTATUS: usize = 1;
const MAX_PROC_MAPS_SIZE: usize = 1024 * 1024;
const DELETED_SUFFIX = " (deleted)";

// Linux x86_64 user_regs_struct layout — used with PTRACE_GETREGS / PTRACE_SETREGS.
// Matches the kernel's struct user_regs_struct from <sys/user.h>.
const X86UserRegs = extern struct {
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

const Aarch64UserRegs = extern struct {
    regs: [31]u64,
    sp: u64,
    pc: u64,
    pstate: u64,
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
                _ = std.os.linux.ptrace(PTRACE_TRACEME, 0, 0, 0, 0);
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
                _ = std.os.linux.ptrace(PTRACE_CONT, pid, 0, 0, 0);
            }
            self.is_running = true;
        }
    }

    pub fn singleStep(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(PTRACE_SINGLESTEP, pid, 0, 0, 0);
            }
            self.is_running = true;
        }
    }

    pub fn waitForStop(self: *PtraceProcessControl) !process_types.WaitResult {
        if (self.pid) |pid| {
            const result = posix.waitpid(pid, WUNTRACED);
            return self.reapStatus(result.status);
        }
        return error.NoProcess;
    }

    /// Wait for a stop event, giving up after `timeout_ms` and returning null.
    ///
    /// Each stop is reported exactly once, so a wait for an event that is never
    /// coming -- SIGSTOP against a process that is already stopped -- blocks
    /// forever. Callers that cannot prove an event is pending must use this
    /// instead of `waitForStop`, because a parked debugger thread stalls every
    /// other tool sharing the server.
    pub fn waitForStopTimeout(self: *PtraceProcessControl, timeout_ms: u64) !?process_types.WaitResult {
        const pid = self.pid orelse return error.NoProcess;
        const deadline_ms = std.time.milliTimestamp() +| @as(i64, @intCast(timeout_ms));
        while (true) {
            const result = posix.waitpid(pid, WUNTRACED | WNOHANG);
            if (result.pid != 0) return self.reapStatus(result.status);
            if (std.time.milliTimestamp() >= deadline_ms) {
                debug_log.log("dwarf.process: pid={d} wait timed out after {d}ms", .{ pid, timeout_ms });
                return null;
            }
            std.Thread.sleep(wait_poll_interval_ns);
        }
    }

    /// Interpret a raw wait status, releasing process state when the child is gone.
    fn reapStatus(self: *PtraceProcessControl, status: u32) process_types.WaitResult {
        self.is_running = false;

        // WIFEXITED: (status & 0x7f) == 0
        if ((status & 0x7f) == 0) {
            self.pid = null;
            return .{ .status = .exited, .exit_code = @intCast((status >> 8) & 0xff) };
        }
        // WIFSIGNALED: low 7 bits are signal number (non-zero, not 0x7f)
        if ((status & 0x7f) != 0 and (status & 0x7f) != 0x7f) {
            self.pid = null;
            return .{ .status = .signaled, .signal = @intCast(status & 0x7f) };
        }
        // WIFSTOPPED: (status & 0xff) == 0x7f
        if ((status & 0xff) == 0x7f) {
            return .{ .status = .stopped, .signal = @intCast((status >> 8) & 0xff) };
        }
        return .{ .status = .unknown };
    }

    /// Read the tracee's general-purpose registers using the native Linux ABI.
    pub fn readRegisters(self: *PtraceProcessControl) !process_types.RegisterState {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        return switch (builtin.cpu.arch) {
            .x86_64 => blk: {
                var regs: X86UserRegs = undefined;
                const rc = std.os.linux.ptrace(PTRACE_GETREGS, pid, 0, @intFromPtr(&regs), 0);
                if (linuxPtraceFailed(rc)) return error.PtraceGetRegsFailed;
                break :blk stateFromX86Registers(regs);
            },
            .aarch64 => blk: {
                var regs: Aarch64UserRegs = undefined;
                var iov = std.posix.iovec{ .base = std.mem.asBytes(&regs).ptr, .len = @sizeOf(Aarch64UserRegs) };
                const rc = std.os.linux.ptrace(PTRACE_GETREGSET, pid, NT_PRSTATUS, @intFromPtr(&iov), 0);
                if (linuxPtraceFailed(rc) or iov.len != @sizeOf(Aarch64UserRegs)) return error.PtraceGetRegsFailed;
                break :blk stateFromAarch64Registers(regs);
            },
            else => error.UnsupportedArchitecture,
        };
    }

    /// Read floating point / SIMD registers from the traced process.
    /// Linux FP register reading via PTRACE_GETREGSET is more complex;
    /// this is a stub that returns empty for now.
    pub fn readFloatRegisters(self: *PtraceProcessControl) !process_types.FloatRegisterState {
        if (self.pid == null) return error.NoProcess;
        // Linux FP register reading via PTRACE_GETREGSET with NT_PRFPREG
        // is more involved and less critical. Return empty state for now.
        return .{};
    }

    /// Write registers back to the tracee using the native Linux ABI.
    pub fn writeRegisters(self: *PtraceProcessControl, regs: process_types.RegisterState) !void {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        switch (builtin.cpu.arch) {
            .x86_64 => {
                // Preserve fields that RegisterState does not represent.
                var kernel_regs: X86UserRegs = undefined;
                var rc = std.os.linux.ptrace(PTRACE_GETREGS, pid, 0, @intFromPtr(&kernel_regs), 0);
                if (linuxPtraceFailed(rc)) return error.PtraceGetRegsFailed;
                applyStateToX86Registers(regs, &kernel_regs);
                rc = std.os.linux.ptrace(PTRACE_SETREGS, pid, 0, @intFromPtr(&kernel_regs), 0);
                if (linuxPtraceFailed(rc)) return error.PtraceSetRegsFailed;
            },
            .aarch64 => {
                var kernel_regs = aarch64RegistersFromState(regs);
                var iov = std.posix.iovec{ .base = std.mem.asBytes(&kernel_regs).ptr, .len = @sizeOf(Aarch64UserRegs) };
                const rc = std.os.linux.ptrace(PTRACE_SETREGSET, pid, NT_PRSTATUS, @intFromPtr(&iov), 0);
                if (linuxPtraceFailed(rc) or iov.len != @sizeOf(Aarch64UserRegs)) return error.PtraceSetRegsFailed;
            },
            else => return error.UnsupportedArchitecture,
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
                const SYS_process_vm_readv = if (builtin.cpu.arch == .aarch64) 270 else 310;
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
                    const rc = std.os.linux.ptrace(PTRACE_PEEKDATA, pid, addr, 0, 0);
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
                    const rc = std.os.linux.ptrace(PTRACE_POKEDATA, pid, addr, word, 0);
                    const signed_rc: isize = @bitCast(rc);
                    if (signed_rc != 0) return error.PtracePokeDataFailed;
                } else {
                    // Partial word at the end: read-modify-write
                    const existing = std.os.linux.ptrace(PTRACE_PEEKDATA, pid, addr, 0, 0);
                    var word: usize = @bitCast(existing);
                    const word_bytes = std.mem.asBytes(&word);
                    @memcpy(word_bytes[0..remaining], data[offset..][0..remaining]);
                    const rc = std.os.linux.ptrace(PTRACE_POKEDATA, pid, addr, word, 0);
                    const signed_rc: isize = @bitCast(rc);
                    if (signed_rc != 0) return error.PtracePokeDataFailed;
                }

                offset += word_size;
            }
        }
    }

    /// Get the executable image base by parsing the bounded /proc process maps.
    pub fn getTextBase(self: *PtraceProcessControl) !u64 {
        const pid = self.pid orelse return error.NoProcess;
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        var maps_path_buf: [64]u8 = undefined;
        const maps_path = std.fmt.bufPrint(&maps_path_buf, "/proc/{d}/maps", .{pid}) catch return error.TextBaseNotFound;
        var exe_path_buf: [64]u8 = undefined;
        const exe_link = std.fmt.bufPrint(&exe_path_buf, "/proc/{d}/exe", .{pid}) catch return error.TextBaseNotFound;

        var executable_buf: [std.fs.max_path_bytes]u8 = undefined;
        const executable_path = std.fs.readLinkAbsolute(exe_link, &executable_buf) catch return error.TextBaseNotFound;
        debug_log.log("ptrace: reading {s} for executable {s}", .{ maps_path, executable_path });

        const file = std.fs.openFileAbsolute(maps_path, .{}) catch return error.TextBaseNotFound;
        defer file.close();
        const maps = file.readToEndAlloc(std.heap.page_allocator, MAX_PROC_MAPS_SIZE) catch |err| switch (err) {
            error.FileTooBig => return error.ProcMapsTooLarge,
            else => return error.TextBaseNotFound,
        };
        defer std.heap.page_allocator.free(maps);

        const base = try parseProcMapsTextBase(maps, executable_path);
        debug_log.log("ptrace: executable base for pid {d} is 0x{x}", .{ pid, base });
        return base;
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
            // Non-blocking reap with bounded retry
            var reaped = false;
            for (0..20) |_| { // ~100ms max (20 * 5ms)
                const result = posix.waitpid(pid, 1); // WNOHANG = 1
                if (result.pid != 0) {
                    reaped = true;
                    break;
                }
                posix.nanosleep(0, 5_000_000); // 5ms
            }
            if (!reaped) {
                _ = posix.waitpid(pid, 0); // final blocking attempt
            }
            self.pid = null;
            self.is_running = false;
        }
    }

    pub fn attach(self: *PtraceProcessControl, pid: posix.pid_t) !void {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.ptrace(PTRACE_ATTACH, pid, 0, 0, 0);
        }
        self.pid = pid;
        self.is_running = false;
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn readCapturedOutput(_: *PtraceProcessControl, _: std.mem.Allocator) !?[]const u8 {
        return null;
    }

    /// Set a hardware watchpoint. Not yet implemented for Linux ptrace.
    pub fn setHardwareWatchpoint(_: *PtraceProcessControl, _: u64, _: u8, _: u8) !u32 {
        return error.NotSupported;
    }

    /// Clear a hardware watchpoint by slot. Not yet implemented for Linux ptrace.
    pub fn clearHardwareWatchpoint(_: *PtraceProcessControl, _: u32) !void {
        return error.NotSupported;
    }

    pub fn detach(self: *PtraceProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.ptrace(PTRACE_DETACH, pid, 0, 0, 0);
            }
            self.pid = null; // We no longer own this process
            self.is_running = false;
        }
    }
};

fn linuxPtraceFailed(result: usize) bool {
    return std.os.linux.E.init(result) != .SUCCESS;
}

fn stateFromX86Registers(regs: X86UserRegs) process_types.RegisterState {
    var state = process_types.RegisterState{};
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

fn applyStateToX86Registers(state: process_types.RegisterState, regs: *X86UserRegs) void {
    regs.rax = state.gprs[0];
    regs.rdx = state.gprs[1];
    regs.rcx = state.gprs[2];
    regs.rbx = state.gprs[3];
    regs.rsi = state.gprs[4];
    regs.rdi = state.gprs[5];
    regs.rbp = state.gprs[6];
    regs.rsp = state.gprs[7];
    regs.r8 = state.gprs[8];
    regs.r9 = state.gprs[9];
    regs.r10 = state.gprs[10];
    regs.r11 = state.gprs[11];
    regs.r12 = state.gprs[12];
    regs.r13 = state.gprs[13];
    regs.r14 = state.gprs[14];
    regs.r15 = state.gprs[15];
    regs.rip = state.pc;
    regs.eflags = state.flags;
}

fn stateFromAarch64Registers(regs: Aarch64UserRegs) process_types.RegisterState {
    var state = process_types.RegisterState{};
    state.gprs[0..31].* = regs.regs;
    state.sp = regs.sp;
    state.pc = regs.pc;
    state.flags = regs.pstate;
    state.fp = regs.regs[29];
    return state;
}

fn aarch64RegistersFromState(state: process_types.RegisterState) Aarch64UserRegs {
    return .{
        .regs = state.gprs[0..31].*,
        .sp = state.sp,
        .pc = state.pc,
        .pstate = state.flags,
    };
}

fn parseProcMapsTextBase(maps: []const u8, executable_path: []const u8) !u64 {
    if (maps.len > MAX_PROC_MAPS_SIZE) return error.ProcMapsTooLarge;
    if (maps.len == 0 or maps[maps.len - 1] != '\n') return error.MalformedProcMaps;

    var base: ?u64 = null;
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const mapping = parseProcMapsLine(line) orelse return error.MalformedProcMaps;
        if (!pathsMatchExecutable(mapping.pathname, executable_path)) continue;

        const candidate = std.math.sub(u64, mapping.start, mapping.file_offset) catch return error.MalformedProcMaps;
        if (base) |existing| {
            if (candidate != existing) return error.MalformedProcMaps;
        } else {
            base = candidate;
        }
    }
    return base orelse error.TextBaseNotFound;
}

const ProcMapsEntry = struct {
    start: u64,
    file_offset: u64,
    pathname: []const u8,
};

fn parseProcMapsLine(line: []const u8) ?ProcMapsEntry {
    var cursor: usize = 0;
    const address_range = nextProcMapsField(line, &cursor) orelse return null;
    const perms = nextProcMapsField(line, &cursor) orelse return null;
    const offset_field = nextProcMapsField(line, &cursor) orelse return null;
    const device = nextProcMapsField(line, &cursor) orelse return null;
    const inode = nextProcMapsField(line, &cursor) orelse return null;
    _ = perms;

    if (std.mem.indexOfScalar(u8, device, ':') == null) return null;
    _ = std.fmt.parseUnsigned(u64, inode, 10) catch return null;

    const dash = std.mem.indexOfScalar(u8, address_range, '-') orelse return null;
    if (dash == 0 or dash + 1 == address_range.len) return null;
    const start = std.fmt.parseUnsigned(u64, address_range[0..dash], 16) catch return null;
    const end = std.fmt.parseUnsigned(u64, address_range[dash + 1 ..], 16) catch return null;
    if (end <= start) return null;
    const file_offset = std.fmt.parseUnsigned(u64, offset_field, 16) catch return null;

    while (cursor < line.len and line[cursor] == ' ') cursor += 1;
    if (cursor == line.len) return null;
    return .{ .start = start, .file_offset = file_offset, .pathname = line[cursor..] };
}

fn nextProcMapsField(line: []const u8, cursor: *usize) ?[]const u8 {
    while (cursor.* < line.len and line[cursor.*] == ' ') cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < line.len and line[cursor.*] != ' ') cursor.* += 1;
    if (start == cursor.*) return null;
    return line[start..cursor.*];
}

fn pathsMatchExecutable(mapping_path: []const u8, executable_path: []const u8) bool {
    const clean_mapping = if (std.mem.endsWith(u8, mapping_path, DELETED_SUFFIX))
        mapping_path[0 .. mapping_path.len - DELETED_SUFFIX.len]
    else
        mapping_path;
    const clean_executable = if (std.mem.endsWith(u8, executable_path, DELETED_SUFFIX))
        executable_path[0 .. executable_path.len - DELETED_SUFFIX.len]
    else
        executable_path;
    return std.mem.eql(u8, clean_mapping, clean_executable);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "PtraceProcessControl initial state" {
    const pc = PtraceProcessControl{};
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}

test "x86 register mapping uses DWARF register slots" {
    var kernel_regs: X86UserRegs = std.mem.zeroes(X86UserRegs);
    kernel_regs.rax = 0;
    kernel_regs.rdx = 1;
    kernel_regs.rcx = 2;
    kernel_regs.rbx = 3;
    kernel_regs.rsi = 4;
    kernel_regs.rdi = 5;
    kernel_regs.rbp = 6;
    kernel_regs.rsp = 7;
    kernel_regs.r8 = 8;
    kernel_regs.r15 = 15;
    kernel_regs.rip = 16;
    kernel_regs.eflags = 17;

    const state = stateFromX86Registers(kernel_regs);
    for (0..9) |index| try std.testing.expectEqual(@as(u64, @intCast(index)), state.gprs[index]);
    try std.testing.expectEqual(@as(u64, 15), state.gprs[15]);
    try std.testing.expectEqual(@as(u64, 16), state.pc);
    try std.testing.expectEqual(@as(u64, 17), state.flags);
    try std.testing.expectEqual(state.gprs[6], state.fp);
    try std.testing.expectEqual(state.gprs[7], state.sp);
}

test "aarch64 register mapping round trips NT_PRSTATUS layout" {
    var state = process_types.RegisterState{};
    for (0..31) |index| state.gprs[index] = 0x100 + index;
    state.sp = 0x200;
    state.pc = 0x201;
    state.flags = 0x202;
    state.fp = state.gprs[29];

    const round_trip = stateFromAarch64Registers(aarch64RegistersFromState(state));
    try std.testing.expectEqualSlices(u64, state.gprs[0..31], round_trip.gprs[0..31]);
    try std.testing.expectEqual(state.sp, round_trip.sp);
    try std.testing.expectEqual(state.pc, round_trip.pc);
    try std.testing.expectEqual(state.flags, round_trip.flags);
    try std.testing.expectEqual(state.fp, round_trip.fp);
}

test "proc maps parser matches executable path with spaces and computes load bias" {
    const maps =
        \\70000000-70001000 r-xp 00000000 08:01 1 /usr/lib/ld-linux.so
        \\55555000-55556000 r--p 00000000 08:01 2 /opt/My Program/bin/app
        \\55556000-55557000 r-xp 00001000 08:01 2 /opt/My Program/bin/app
        \\55557000-55558000 rw-p 00002000 08:01 2 /opt/My Program/bin/app
        \\
    ;
    try std.testing.expectEqual(@as(u64, 0x55555000), try parseProcMapsTextBase(maps, "/opt/My Program/bin/app"));
}

test "proc maps parser accepts deleted executable suffix" {
    const maps =
        \\400000-401000 r--p 00000000 08:01 2 /tmp/app (deleted)
        \\401000-402000 r-xp 00001000 08:01 2 /tmp/app (deleted)
        \\
    ;
    try std.testing.expectEqual(@as(u64, 0x400000), try parseProcMapsTextBase(maps, "/tmp/app"));
    try std.testing.expectEqual(@as(u64, 0x400000), try parseProcMapsTextBase(maps, "/tmp/app (deleted)"));
}

test "proc maps parser ignores other executable mappings" {
    const maps =
        \\70000000-70001000 r-xp 00000000 08:01 1 /usr/lib/loader.so
        \\400000-401000 r-xp 00000000 08:01 2 /usr/bin/target
        \\
    ;
    try std.testing.expectEqual(@as(u64, 0x400000), try parseProcMapsTextBase(maps, "/usr/bin/target"));
}

test "proc maps parser rejects malformed and truncated input" {
    try std.testing.expectError(error.MalformedProcMaps, parseProcMapsTextBase("not a maps line\n", "/usr/bin/app"));
    try std.testing.expectError(
        error.MalformedProcMaps,
        parseProcMapsTextBase("400000-401000 r-xp 00000000 08:01 2 /usr/bin/app", "/usr/bin/app"),
    );
}

test "proc maps parser rejects oversized input" {
    const maps = try std.testing.allocator.alloc(u8, MAX_PROC_MAPS_SIZE + 1);
    defer std.testing.allocator.free(maps);
    @memset(maps, '\n');
    try std.testing.expectError(error.ProcMapsTooLarge, parseProcMapsTextBase(maps, "/usr/bin/app"));
}

test "proc maps parser reports no executable pathname match" {
    const maps = "400000-401000 r-xp 00000000 08:01 2 /usr/bin/other\n";
    try std.testing.expectError(error.TextBaseNotFound, parseProcMapsTextBase(maps, "/usr/bin/app"));
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
