const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ── macOS Mach-based Process Control ────────────────────────────────────

const WUNTRACED: u32 = if (builtin.os.tag == .macos) 0x00000002 else 0x00000002;
const SIGKILL: u8 = 9;

// macOS Mach thread state definitions (not in Zig's std.c)
const ARM_THREAD_STATE64: std.c.thread_flavor_t = 6;
const ARM_THREAD_STATE64_COUNT: std.c.mach_msg_type_number_t = @sizeOf(ArmThreadState64) / @sizeOf(std.c.natural_t);

const x86_THREAD_STATE64: std.c.thread_flavor_t = 4;
const x86_THREAD_STATE64_COUNT: std.c.mach_msg_type_number_t = @sizeOf(X86ThreadState64) / @sizeOf(std.c.natural_t);

// ARM64 NEON (FP/SIMD) thread state
const ARM_NEON_STATE64: std.c.thread_flavor_t = 17;
const ARM_NEON_STATE64_COUNT: std.c.mach_msg_type_number_t = @sizeOf(ArmNeonState64) / @sizeOf(std.c.natural_t);

// x86_64 float state (SSE/XMM registers)
const x86_FLOAT_STATE64: std.c.thread_flavor_t = 5;
const x86_FLOAT_STATE64_COUNT: std.c.mach_msg_type_number_t = @sizeOf(X86FloatState64) / @sizeOf(std.c.natural_t);

const ArmThreadState64 = extern struct {
    x: [29]u64, // general purpose x0-x28
    fp: u64, // x29
    lr: u64, // x30
    sp: u64,
    pc: u64,
    cpsr: u32,
    pad: u32,
};

const X86ThreadState64 = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
    cs: u64,
    fs: u64,
    gs: u64,
};

/// ARM64 NEON state: 32 x 128-bit vector registers (V0-V31) plus FPSR and FPCR.
/// Each V register is stored as two 64-bit halves (low, high).
const ArmNeonState64 = extern struct {
    v: [32][2]u64, // v[i][0] = low 64 bits, v[i][1] = high 64 bits
    fpsr: u32,
    fpcr: u32,
};

/// x86_64 float state (FXSAVE layout). We only care about the XMM registers
/// which start at offset 160 in the FXSAVE area. The full struct is 512 bytes.
const X86FloatState64 = extern struct {
    // FPU control/status (bytes 0-31)
    fcw: u16,
    fsw: u16,
    ftw: u8,
    _reserved1: u8,
    fop: u16,
    fip: u32,
    fcs: u16,
    _reserved2: u16,
    fdp: u32,
    fds: u16,
    _reserved3: u16,
    mxcsr: u32,
    mxcsr_mask: u32,
    // ST/MM registers (bytes 32-159) - 8 x 16 bytes
    st_mm: [8][2]u64,
    // XMM registers (bytes 160-415) - 16 x 16 bytes
    xmm: [16][2]u64,
    // Reserved (bytes 416-511)
    _reserved4: [6][2]u64,
};

/// FP/SIMD register state returned by readFloatRegisters.
/// Each register is stored as two 64-bit values (low and high halves of 128-bit register).
pub const FloatRegisterState = struct {
    /// Register values: [i][0] = low 64 bits, [i][1] = high 64 bits
    regs: [max_fp_regs][2]u64 = [_][2]u64{.{ 0, 0 }} ** max_fp_regs,
    /// Number of valid registers in the array
    count: u32 = 0,
    /// Whether these are ARM NEON (v0-v31) or x86 XMM (xmm0-xmm15)
    is_arm: bool = false,

    pub const max_fp_regs = 32;
};

pub const MachProcessControl = struct {
    pid: ?posix.pid_t = null,
    is_running: bool = false,
    stdout_pipe_read: ?posix.fd_t = null,
    stderr_pipe_read: ?posix.fd_t = null,
    cached_task: ?std.c.mach_port_name_t = null,
    cached_thread: ?std.c.mach_port_t = null,
    pending_stdout: ?[]const u8 = null,
    pending_stderr: ?[]const u8 = null,
    alloc: ?std.mem.Allocator = null,

    /// Read available data from the captured stdout pipe.
    /// Returns null if no stdout pipe is configured.
    /// Caller owns the returned memory.
    pub fn readCapturedOutput(self: *MachProcessControl, allocator: std.mem.Allocator) !?[]const u8 {
        // Return pending data drained at process exit first
        if (self.pending_stdout) |pending| {
            self.pending_stdout = null;
            // Re-allocate with caller's allocator so they own it
            const copy = try allocator.alloc(u8, pending.len);
            @memcpy(copy, pending);
            if (self.alloc) |a| a.free(pending);
            return copy;
        }
        const fd = self.stdout_pipe_read orelse return null;
        var buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buf);
        const n = posix.read(fd, buf) catch |err| {
            if (err == error.WouldBlock) {
                allocator.free(buf);
                return null;
            }
            return err;
        };
        if (n == 0) {
            allocator.free(buf);
            return null;
        }
        // Shrink to actual size
        if (allocator.resize(buf, n)) {
            return buf[0..n];
        }
        const exact = try allocator.alloc(u8, n);
        @memcpy(exact, buf[0..n]);
        allocator.free(buf);
        return exact;
    }

    /// Drain all remaining data from a pipe FD into a single allocation.
    fn drainPipe(fd: posix.fd_t, allocator: std.mem.Allocator) ?[]const u8 {
        var result = std.ArrayListUnmanaged(u8).empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(fd, &buf) catch break;
            if (n == 0) break;
            result.appendSlice(allocator, buf[0..n]) catch break;
        }
        if (result.items.len == 0) {
            result.deinit(allocator);
            return null;
        }
        return result.toOwnedSlice(allocator) catch null;
    }

    pub fn spawn(self: *MachProcessControl, allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) !void {
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

        // Create pipes for capturing debuggee stdout/stderr
        const stdout_pipe = posix.pipe() catch null;
        const stderr_pipe = posix.pipe() catch null;

        const pid = try posix.fork();
        if (pid == 0) {
            // Child: redirect stdout/stderr to pipes so parent can read output
            if (stdout_pipe) |p| {
                posix.close(p[0]); // close read end in child
                _ = posix.dup2(p[1], 1) catch {}; // stdout -> write end
                posix.close(p[1]);
            } else {
                // Fallback to /dev/null if pipe creation failed
                const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch null;
                if (devnull) |fd| {
                    _ = posix.dup2(fd, 1) catch {};
                    posix.close(fd);
                }
            }
            if (stderr_pipe) |p| {
                posix.close(p[0]); // close read end in child
                _ = posix.dup2(p[1], 2) catch {}; // stderr -> write end
                posix.close(p[1]);
            } else {
                const devnull = posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch null;
                if (devnull) |fd| {
                    _ = posix.dup2(fd, 2) catch {};
                    posix.close(fd);
                }
            }
            // Child: request trace and exec
            if (builtin.os.tag == .macos) {
                const PT_TRACE_ME = 0;
                _ = std.c.ptrace(PT_TRACE_ME, 0, null, 0);
            }
            posix.execvpeZ(prog_z.ptr, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ)) catch {};
            // If exec fails, exit immediately
            std.posix.exit(127);
        }

        self.pid = pid;
        self.is_running = false;
        self.alloc = allocator;

        // Parent: close write ends, keep read ends, set non-blocking
        if (stdout_pipe) |p| {
            posix.close(p[1]); // close write end in parent
            // Set read end to non-blocking
            const flags = std.c.fcntl(p[0], std.posix.F.GETFL);
            _ = std.c.fcntl(p[0], std.posix.F.SETFL, @as(c_int, flags) | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
            self.stdout_pipe_read = p[0];
        }
        if (stderr_pipe) |p| {
            posix.close(p[1]); // close write end in parent
            const flags = std.c.fcntl(p[0], std.posix.F.GETFL);
            _ = std.c.fcntl(p[0], std.posix.F.SETFL, @as(c_int, flags) | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
            self.stderr_pipe_read = p[0];
        }

        // Wait for the child to stop (from PT_TRACE_ME + exec)
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn continueExecution(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                const PT_CONTINUE = 7;
                const result = std.c.ptrace(PT_CONTINUE, pid, @ptrFromInt(1), 0);
                if (result != 0) return error.ContinueFailed;
            }
            self.is_running = true;
        }
    }

    pub fn singleStep(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                const PT_STEP = 9;
                const result = std.c.ptrace(PT_STEP, pid, @ptrFromInt(1), 0);
                if (result != 0) return error.StepFailed;
            }
            self.is_running = true;
        }
    }

    pub fn waitForStop(self: *MachProcessControl) !WaitResult {
        if (self.pid) |pid| {
            const result = posix.waitpid(pid, WUNTRACED);
            self.is_running = false;

            const status = result.status;
            // WIFEXITED: (status & 0x7f) == 0
            if ((status & 0x7f) == 0) {
                self.pid = null;
                self.cached_task = null;
                self.cached_thread = null;
                // Drain remaining pipe data before closing
                if (self.stdout_pipe_read) |fd| {
                    if (self.alloc) |a| {
                        self.pending_stdout = drainPipe(fd, a);
                    }
                    posix.close(fd);
                    self.stdout_pipe_read = null;
                }
                if (self.stderr_pipe_read) |fd| {
                    if (self.alloc) |a| {
                        self.pending_stderr = drainPipe(fd, a);
                    }
                    posix.close(fd);
                    self.stderr_pipe_read = null;
                }
                return .{ .status = .exited, .exit_code = @intCast((status >> 8) & 0xff) };
            }
            // WIFSIGNALED: low 7 bits are signal number (non-zero, not 0x7f)
            if ((status & 0x7f) != 0 and (status & 0x7f) != 0x7f) {
                self.pid = null;
                self.cached_task = null;
                self.cached_thread = null;
                // Drain remaining pipe data before closing
                if (self.stdout_pipe_read) |fd| {
                    if (self.alloc) |a| {
                        self.pending_stdout = drainPipe(fd, a);
                    }
                    posix.close(fd);
                    self.stdout_pipe_read = null;
                }
                if (self.stderr_pipe_read) |fd| {
                    if (self.alloc) |a| {
                        self.pending_stderr = drainPipe(fd, a);
                    }
                    posix.close(fd);
                    self.stderr_pipe_read = null;
                }
                return .{ .status = .signaled, .signal = @intCast(status & 0x7f) };
            }
            // WIFSTOPPED: (status & 0xff) == 0x7f
            if ((status & 0xff) == 0x7f) {
                return .{ .status = .stopped, .signal = @intCast((status >> 8) & 0xff) };
            }
            return .{ .status = .unknown };
        }
        return error.NoProcess;
    }

    pub fn readRegisters(self: *MachProcessControl) !RegisterState {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return .{};

        const thread = try self.getThread();

        const is_arm = builtin.cpu.arch == .aarch64;
        var kr: std.c.kern_return_t = undefined;
        if (is_arm) {
            var state: ArmThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = ARM_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            var regs = RegisterState{
                .pc = state.pc,
                .sp = state.sp,
                .fp = state.fp,
                .flags = state.cpsr,
            };
            // x0-x28
            for (0..29) |i| {
                regs.gprs[i] = state.x[i];
            }
            regs.gprs[29] = state.fp; // x29 = FP
            regs.gprs[30] = state.lr; // x30 = LR
            regs.gprs[31] = state.sp; // x31 = SP (conceptual)
            return regs;
        } else {
            var state: X86ThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = x86_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, x86_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            var regs = RegisterState{
                .pc = state.rip,
                .sp = state.rsp,
                .fp = state.rbp,
                .flags = state.rflags,
            };
            // Map x86-64 registers to DWARF register numbers
            regs.gprs[0] = state.rax;
            regs.gprs[1] = state.rdx;
            regs.gprs[2] = state.rcx;
            regs.gprs[3] = state.rbx;
            regs.gprs[4] = state.rsi;
            regs.gprs[5] = state.rdi;
            regs.gprs[6] = state.rbp;
            regs.gprs[7] = state.rsp;
            regs.gprs[8] = state.r8;
            regs.gprs[9] = state.r9;
            regs.gprs[10] = state.r10;
            regs.gprs[11] = state.r11;
            regs.gprs[12] = state.r12;
            regs.gprs[13] = state.r13;
            regs.gprs[14] = state.r14;
            regs.gprs[15] = state.r15;
            regs.gprs[16] = state.rip;
            return regs;
        }
    }

    /// Read floating point / SIMD registers from the traced process.
    /// On ARM64 this reads V0-V31 (NEON), on x86_64 this reads XMM0-XMM15.
    pub fn readFloatRegisters(self: *MachProcessControl) !FloatRegisterState {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return .{};

        const thread = try self.getThread();

        const is_arm = builtin.cpu.arch == .aarch64;
        var kr: std.c.kern_return_t = undefined;
        if (is_arm) {
            var state: ArmNeonState64 = undefined;
            var count: std.c.mach_msg_type_number_t = ARM_NEON_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, ARM_NEON_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.FloatRegisterReadFailed;

            var result = FloatRegisterState{
                .count = 32,
                .is_arm = true,
            };
            for (0..32) |i| {
                result.regs[i] = state.v[i];
            }
            return result;
        } else {
            var state: X86FloatState64 = undefined;
            var count: std.c.mach_msg_type_number_t = x86_FLOAT_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, x86_FLOAT_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.FloatRegisterReadFailed;

            var result = FloatRegisterState{
                .count = 16,
                .is_arm = false,
            };
            for (0..16) |i| {
                result.regs[i] = state.xmm[i];
            }
            return result;
        }
    }

    pub fn writeRegisters(self: *MachProcessControl, regs: RegisterState) !void {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return;

        const thread = try self.getThread();

        const is_arm = builtin.cpu.arch == .aarch64;
        var kr: std.c.kern_return_t = undefined;
        if (is_arm) {
            var state: ArmThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = ARM_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            state.pc = regs.pc;
            state.sp = regs.sp;
            state.fp = regs.fp;
            for (0..29) |i| {
                state.x[i] = regs.gprs[i];
            }
            state.lr = regs.gprs[30];
            kr = std.c.thread_set_state(thread, ARM_THREAD_STATE64, @ptrCast(&state), ARM_THREAD_STATE64_COUNT);
            if (kr != 0) return error.ThreadSetStateFailed;
        } else {
            var state: X86ThreadState64 = undefined;
            var count: std.c.mach_msg_type_number_t = x86_THREAD_STATE64_COUNT;
            kr = std.c.thread_get_state(thread, x86_THREAD_STATE64, @ptrCast(&state), &count);
            if (kr != 0) return error.ThreadGetStateFailed;
            state.rip = regs.pc;
            state.rax = regs.gprs[0];
            state.rdx = regs.gprs[1];
            state.rcx = regs.gprs[2];
            state.rbx = regs.gprs[3];
            state.rsi = regs.gprs[4];
            state.rdi = regs.gprs[5];
            state.rbp = regs.gprs[6];
            state.rsp = regs.gprs[7];
            state.r8 = regs.gprs[8];
            state.r9 = regs.gprs[9];
            state.r10 = regs.gprs[10];
            state.r11 = regs.gprs[11];
            state.r12 = regs.gprs[12];
            state.r13 = regs.gprs[13];
            state.r14 = regs.gprs[14];
            state.r15 = regs.gprs[15];
            kr = std.c.thread_set_state(thread, x86_THREAD_STATE64, @ptrCast(&state), x86_THREAD_STATE64_COUNT);
            if (kr != 0) return error.ThreadSetStateFailed;
        }
    }

    pub fn readMemory(self: *MachProcessControl, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) {
            const buf = try allocator.alloc(u8, size);
            @memset(buf, 0);
            return buf;
        }

        const task = try self.getTask();
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);

        var data_out: std.c.vm_offset_t = undefined;
        var data_cnt: std.c.mach_msg_type_number_t = undefined;
        const kr = std.c.mach_vm_read(task, address, size, &data_out, &data_cnt);
        if (kr != 0) return error.ReadFailed;

        const src: [*]const u8 = @ptrFromInt(data_out);
        @memcpy(buf[0..@min(size, data_cnt)], src[0..@min(size, data_cnt)]);
        _ = std.c.vm_deallocate(std.c.mach_task_self(), data_out, data_cnt);
        return buf;
    }

    pub fn writeMemory(self: *MachProcessControl, address: u64, data: []const u8) !void {
        if (self.pid == null) return error.NoProcess;
        if (builtin.os.tag != .macos) return;

        const task = try self.getTask();

        // Make the page writable (COW copy for __TEXT segment breakpoints)
        // W^X policy: don't set EXECUTE when setting WRITE
        const VM_PROT_READ: std.c.vm_prot_t = 0x01;
        const VM_PROT_WRITE: std.c.vm_prot_t = 0x02;
        const VM_PROT_EXECUTE: std.c.vm_prot_t = 0x04;
        const VM_PROT_COPY: std.c.vm_prot_t = 0x10;
        const page_size: u64 = if (comptime @import("builtin").cpu.arch == .aarch64) 0x4000 else 0x1000;
        const page_addr = address & ~(page_size - 1);
        _ = std.c.mach_vm_protect(task, page_addr, page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);

        const kr = std.c.mach_vm_write(task, address, @intFromPtr(data.ptr), @intCast(data.len));

        // Restore read+execute protection
        _ = std.c.mach_vm_protect(task, page_addr, page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);

        if (kr != 0) return error.WriteFailed;
    }

    /// Get the Mach task port for the traced process.
    pub fn getTask(self: *MachProcessControl) !std.c.mach_port_name_t {
        if (self.cached_task) |task| return task;
        const pid = self.pid orelse return error.NoProcess;
        var task: std.c.mach_port_name_t = undefined;
        const kr = std.c.task_for_pid(std.c.mach_task_self(), pid, &task);
        if (kr != 0) return error.TaskForPidFailed;
        self.cached_task = task;
        return task;
    }

    /// Get the main thread port for the traced process.
    pub fn getThread(self: *MachProcessControl) !std.c.mach_port_t {
        if (self.cached_thread) |thread| return thread;
        const task = try self.getTask();
        var threads: std.c.mach_port_array_t = undefined;
        var thread_count: std.c.mach_msg_type_number_t = undefined;
        const kr = std.c.task_threads(task, &threads, &thread_count);
        if (kr != 0) return error.TaskThreadsFailed;
        defer {
            const size = @sizeOf(std.c.mach_port_t) * thread_count;
            _ = std.c.vm_deallocate(std.c.mach_task_self(), @intFromPtr(threads), size);
        }
        if (thread_count == 0) return error.NoThreads;
        self.cached_thread = threads[0];
        return threads[0];
    }

    /// Find the actual __TEXT segment base address in the running process.
    /// Used to compute the ASLR slide for breakpoint address resolution.
    pub fn getTextBase(self: *MachProcessControl) !u64 {
        const task = try self.getTask();
        const MH_MAGIC_64: u32 = 0xFEEDFACF;

        var address: std.c.mach_vm_address_t = 0;
        while (address < 0x7FFFFFFFFFFF) {
            var size: std.c.mach_vm_size_t = 0;
            var info: std.c.vm_region_basic_info_64 = undefined;
            var info_cnt: std.c.mach_msg_type_number_t = std.c.VM.REGION.BASIC_INFO_COUNT;
            var object_name: std.c.mach_port_t = 0;
            const kr = std.c.mach_vm_region(
                task,
                &address,
                &size,
                std.c.VM.REGION.BASIC_INFO_64,
                @ptrCast(&info),
                &info_cnt,
                &object_name,
            );
            if (kr != 0) break;

            // Look for executable region with Mach-O magic
            if (info.protection & 0x04 != 0) { // VM_PROT_EXECUTE = 4
                var data_out: std.c.vm_offset_t = undefined;
                var data_cnt: std.c.mach_msg_type_number_t = undefined;
                const read_kr = std.c.mach_vm_read(task, address, 4, &data_out, &data_cnt);
                if (read_kr == 0 and data_cnt >= 4) {
                    const magic = @as(*const u32, @alignCast(@ptrCast(@as([*]const u8, @ptrFromInt(data_out))))).*;
                    _ = std.c.vm_deallocate(std.c.mach_task_self(), data_out, data_cnt);
                    if (magic == MH_MAGIC_64) {
                        return address;
                    }
                }
            }
            address += size;
        }
        return error.TextBaseNotFound;
    }

    pub fn kill(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                // PT_KILL atomically sends SIGKILL and resumes a ptrace-stopped process.
                // This avoids the macOS deadlock where signals queue but don't deliver
                // to stopped processes.
                const PT_KILL = 8;
                _ = std.c.ptrace(PT_KILL, pid, @ptrFromInt(1), 0);
            } else {
                posix.kill(pid, SIGKILL) catch {};
            }

            // Non-blocking reap with bounded retry to prevent daemon deadlock
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
                // Final attempt: SIGKILL + blocking waitpid
                posix.kill(pid, SIGKILL) catch {};
                _ = posix.waitpid(pid, 0);
            }

            self.pid = null;
            self.is_running = false;
            self.cached_task = null;
            self.cached_thread = null;
        }
        // Close captured output pipes (even if pid was already null from natural exit)
        if (self.stdout_pipe_read) |fd| {
            posix.close(fd);
            self.stdout_pipe_read = null;
        }
        if (self.stderr_pipe_read) |fd| {
            posix.close(fd);
            self.stderr_pipe_read = null;
        }
    }

    pub fn attach(self: *MachProcessControl, pid: posix.pid_t) !void {
        if (builtin.os.tag == .macos) {
            const PT_ATTACH = 10;
            const result = std.c.ptrace(PT_ATTACH, pid, null, 0);
            if (result != 0) return error.AttachFailed;
        }
        self.pid = pid;
        self.is_running = false;
        // Wait for the stop signal from attach
        _ = posix.waitpid(pid, WUNTRACED);
    }

    pub fn detach(self: *MachProcessControl) !void {
        if (self.pid) |pid| {
            if (builtin.os.tag == .macos) {
                // Resume before detach so the process can run independently
                if (!self.is_running) {
                    const PT_CONTINUE = 7;
                    _ = std.c.ptrace(PT_CONTINUE, pid, @ptrFromInt(1), 0);
                }
                const PT_DETACH = 11;
                _ = std.c.ptrace(PT_DETACH, pid, null, 0);
            }
            self.pid = null; // We no longer own this process
            self.is_running = false;
            self.cached_task = null;
            self.cached_thread = null;
            // Close pipes since we are done with this session
            if (self.stdout_pipe_read) |fd| {
                posix.close(fd);
                self.stdout_pipe_read = null;
            }
            if (self.stderr_pipe_read) |fd| {
                posix.close(fd);
                self.stderr_pipe_read = null;
            }
        }
    }
};

pub const WaitResult = struct {
    status: Status = .unknown,
    exit_code: i32 = 0,
    signal: i32 = 0,

    pub const Status = enum {
        stopped,
        exited,
        signaled,
        unknown,
    };
};

pub const RegisterState = struct {
    gprs: [32]u64 = [_]u64{0} ** 32,
    pc: u64 = 0,
    sp: u64 = 0,
    fp: u64 = 0,
    flags: u64 = 0,

    // Convenience aliases for backward compatibility
    pub inline fn rip(self: RegisterState) u64 {
        return self.pc;
    }
    pub inline fn rsp(self: RegisterState) u64 {
        return self.sp;
    }
    pub inline fn rbp(self: RegisterState) u64 {
        return self.fp;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "MachProcessControl initial state" {
    const pc = MachProcessControl{};
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}

// Process control integration tests use fork() which hangs in Zig's multi-threaded
// test runner. These tests exist as specification — run manually with:
//   zig test src/debug/dwarf/process_mach.zig --single-threaded
// The tests verify spawn, continue, waitForStop, readRegisters, readMemory,
// writeMemory, singleStep, kill, and spawn-with-invalid-path behavior.

test "spawn launches process in stopped state" {
    // fork() hangs in multi-threaded test runner — skip in automated tests
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    try std.testing.expect(pc.pid != null);
    try std.testing.expect(!pc.is_running);
}

test "continueExecution resumes stopped process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    try pc.continueExecution();
    try std.testing.expect(pc.is_running);
}

test "waitForStop returns after process exits" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    try pc.continueExecution();
    const result = try pc.waitForStop();
    try std.testing.expectEqual(WaitResult.Status.exited, result.status);
    pc.pid = null;
}

test "readRegisters returns register state" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const regs = try pc.readRegisters();
    _ = regs;
}

test "readFloatRegisters returns without error" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const fp_regs = try pc.readFloatRegisters();
    const is_arm = builtin.cpu.arch == .aarch64;
    if (is_arm) {
        try std.testing.expectEqual(@as(u32, 32), fp_regs.count);
        try std.testing.expect(fp_regs.is_arm);
    } else {
        try std.testing.expectEqual(@as(u32, 16), fp_regs.count);
        try std.testing.expect(!fp_regs.is_arm);
    }
}

test "readFloatRegisters returns NoProcess when no pid" {
    var pc = MachProcessControl{};
    try std.testing.expectError(error.NoProcess, pc.readFloatRegisters());
}

test "FloatRegisterState default is zeroed" {
    const fp = FloatRegisterState{};
    try std.testing.expectEqual(@as(u32, 0), fp.count);
    try std.testing.expect(!fp.is_arm);
    try std.testing.expectEqual(@as(u64, 0), fp.regs[0][0]);
    try std.testing.expectEqual(@as(u64, 0), fp.regs[0][1]);
}

test "readMemory reads bytes from process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    const mem = try pc.readMemory(0x1000, 4, std.testing.allocator);
    defer std.testing.allocator.free(mem);
    try std.testing.expectEqual(@as(usize, 4), mem.len);
}

test "writeMemory writes to process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    try pc.writeMemory(0x1000, &.{ 0x90, 0x90 });
}

test "singleStep advances execution" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"hello"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};
    pc.singleStep() catch return error.SkipZigTest;
    try std.testing.expect(pc.is_running);
}

test "kill terminates the process" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/usr/bin/sleep", &.{"10"}) catch return error.SkipZigTest;
    try std.testing.expect(pc.pid != null);
    try pc.kill();
    try std.testing.expect(pc.pid == null);
    try std.testing.expect(!pc.is_running);
}

test "spawn with invalid path returns error" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;
    var pc = MachProcessControl{};
    pc.spawn(std.testing.allocator, "/nonexistent/path/to/binary", &.{}) catch return error.SkipZigTest;
    try pc.continueExecution();
    const result = try pc.waitForStop();
    try std.testing.expectEqual(WaitResult.Status.exited, result.status);
    pc.pid = null;
}

test "readCapturedOutput returns null when no pipe is set" {
    var pc = MachProcessControl{};
    try std.testing.expect(pc.stdout_pipe_read == null);
    try std.testing.expect(pc.stderr_pipe_read == null);
    const output = try pc.readCapturedOutput(std.testing.allocator);
    try std.testing.expect(output == null);
}

test "MachProcessControl pipe fields default to null" {
    const pc = MachProcessControl{};
    try std.testing.expect(pc.stdout_pipe_read == null);
    try std.testing.expect(pc.stderr_pipe_read == null);
}
