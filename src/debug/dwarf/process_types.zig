/// Platform-neutral types shared between process_mach.zig, process_ptrace.zig,
/// and core_dump.zig. Extracted so that no file needs to transitively import
/// macOS-only Mach headers just to use these data structures.
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
