const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("../../debug_log.zig");
const process_types = @import("process_types.zig");

const RegisterState = process_types.RegisterState;

// ── Core Dump Loading ─────────────────────────────────────────────────
//
// Parses ELF and Mach-O core dumps for post-mortem debugging.
// Provides readMemory/readRegisters without a live process.

pub const CoreDump = struct {
    data: []const u8, // file contents
    segments: []const Segment, // PT_LOAD / LC_SEGMENT_64 entries
    registers: RegisterState, // from NT_PRSTATUS / LC_THREAD
    allocator: std.mem.Allocator,

    pub const Segment = struct {
        vaddr: u64,
        file_offset: u64,
        file_size: u64,
        mem_size: u64,
    };

    pub fn load(allocator: std.mem.Allocator, core_path: []const u8) !CoreDump {
        debug_log.log("core dump: opening {s}", .{core_path});
        const file = try std.fs.cwd().openFile(core_path, .{});
        defer file.close();

        const stat = try file.stat();
        debug_log.log("core dump: reading {d} bytes from {s}", .{ stat.size, core_path });
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read < 16) {
            allocator.free(data);
            return error.InvalidCoreFile;
        }

        // Check magic bytes
        if (data[0] == 0x7f and data[1] == 'E' and data[2] == 'L' and data[3] == 'F') {
            return parseElfCore(allocator, data);
        } else if (std.mem.readInt(u32, data[0..4], .little) == 0xFEEDFACF) {
            return parseMachOCore(allocator, data);
        } else {
            allocator.free(data);
            return error.InvalidCoreFile;
        }
    }

    pub fn readMemory(self: *const CoreDump, address: u64, size: usize, allocator: std.mem.Allocator) ![]u8 {
        for (self.segments) |seg| {
            if (address >= seg.vaddr and address < seg.vaddr + seg.file_size) {
                const offset_in_seg = address - seg.vaddr;
                const available = seg.file_size - offset_in_seg;
                const read_size = @min(size, available);
                if (read_size == 0) return error.AddressNotMapped;

                const file_pos = seg.file_offset + offset_in_seg;
                if (file_pos + read_size > self.data.len) return error.AddressNotMapped;

                const result = try allocator.alloc(u8, read_size);
                @memcpy(result, self.data[file_pos..][0..read_size]);
                return result;
            }
        }
        return error.AddressNotMapped;
    }

    pub fn readRegisters(self: *const CoreDump) RegisterState {
        return self.registers;
    }

    pub fn deinit(self: *CoreDump) void {
        if (self.segments.len > 0) self.allocator.free(self.segments);
        self.allocator.free(self.data);
    }

    // ── ELF Core Parsing ────────────────────────────────────────────

    const Elf64Phdr = extern struct {
        p_type: u32,
        p_flags: u32,
        p_offset: u64,
        p_vaddr: u64,
        p_paddr: u64,
        p_filesz: u64,
        p_memsz: u64,
        p_align: u64,
    };

    const Elf64Nhdr = extern struct {
        n_namesz: u32,
        n_descsz: u32,
        n_type: u32,
    };

    const ET_CORE: u16 = 4;
    const PT_LOAD: u32 = 1;
    const PT_NOTE: u32 = 4;
    const NT_PRSTATUS: u32 = 1;
    const EM_X86_64: u16 = 62;
    const EM_AARCH64: u16 = 183;

    fn parseElfCore(allocator: std.mem.Allocator, data: []const u8) !CoreDump {
        if (data.len < 64) return error.InvalidCoreFile; // ELF64 header is 64 bytes

        // Verify the complete ELF64 little-endian identification, core type, and
        // a register architecture that this reader understands.
        if (!std.mem.eql(u8, data[0..4], "\x7fELF")) return error.InvalidCoreFile;
        if (data[4] != 2 or data[5] != 1 or data[6] != 1) return error.InvalidCoreFile;

        const e_type = std.mem.readInt(u16, data[16..18], .little);
        if (e_type != ET_CORE) return error.InvalidCoreFile;

        const target_arch: std.Target.Cpu.Arch = switch (std.mem.readInt(u16, data[18..20], .little)) {
            EM_X86_64 => .x86_64,
            EM_AARCH64 => .aarch64,
            else => return error.UnsupportedArchitecture,
        };
        debug_log.log("core dump: parsing ELF64 {s} core", .{@tagName(target_arch)});

        const e_phoff = std.mem.readInt(u64, data[32..40], .little);
        const e_ehsize = std.mem.readInt(u16, data[52..54], .little);
        const e_phentsize = std.mem.readInt(u16, data[54..56], .little);
        const e_phnum = std.mem.readInt(u16, data[56..58], .little);
        if (e_ehsize != 64 or e_phentsize != @sizeOf(Elf64Phdr)) return error.InvalidCoreFile;

        var segments = std.ArrayListUnmanaged(Segment){};
        errdefer segments.deinit(allocator);
        var registers = RegisterState{};
        var found_regs = false;

        const ph_table_size = std.math.mul(u64, e_phentsize, e_phnum) catch return error.InvalidCoreFile;
        const ph_table_end = std.math.add(u64, e_phoff, ph_table_size) catch return error.InvalidCoreFile;
        if (ph_table_end > data.len) return error.InvalidCoreFile;

        var i: u16 = 0;
        while (i < e_phnum) : (i += 1) {
            const ph_offset = e_phoff + @as(u64, i) * @as(u64, e_phentsize);
            const phdr = std.mem.bytesAsValue(Elf64Phdr, data[ph_offset..][0..@sizeOf(Elf64Phdr)]);

            const segment_end = std.math.add(u64, phdr.p_offset, phdr.p_filesz) catch return error.InvalidCoreFile;
            if (segment_end > data.len) return error.InvalidCoreFile;

            if (phdr.p_type == PT_LOAD) {
                try segments.append(allocator, .{
                    .vaddr = phdr.p_vaddr,
                    .file_offset = phdr.p_offset,
                    .file_size = phdr.p_filesz,
                    .mem_size = phdr.p_memsz,
                });
            } else if (phdr.p_type == PT_NOTE and !found_regs) {
                // Parse NOTE segment for NT_PRSTATUS.
                if (try parseElfNotes(data, phdr.p_offset, phdr.p_filesz, target_arch)) |regs| {
                    registers = regs;
                    found_regs = true;
                }
            }
        }

        return .{
            .data = data,
            .segments = try segments.toOwnedSlice(allocator),
            .registers = registers,
            .allocator = allocator,
        };
    }

    fn parseElfNotes(
        data: []const u8,
        note_offset: u64,
        note_size: u64,
        target_arch: std.Target.Cpu.Arch,
    ) !?RegisterState {
        const end = std.math.add(u64, note_offset, note_size) catch return error.InvalidCoreFile;
        if (end > data.len) return error.InvalidCoreFile;

        var offset = note_offset;
        while (offset < end) {
            const header_end = std.math.add(u64, offset, @sizeOf(Elf64Nhdr)) catch return error.InvalidCoreFile;
            if (header_end > end) return error.InvalidCoreFile;

            const nhdr = std.mem.bytesAsValue(Elf64Nhdr, data[offset..][0..@sizeOf(Elf64Nhdr)]);
            offset = header_end;

            const name_aligned = std.mem.alignForward(u64, nhdr.n_namesz, 4);
            const name_end = std.math.add(u64, offset, nhdr.n_namesz) catch return error.InvalidCoreFile;
            const desc_start = std.math.add(u64, offset, name_aligned) catch return error.InvalidCoreFile;
            const desc_end = std.math.add(u64, desc_start, nhdr.n_descsz) catch return error.InvalidCoreFile;
            const desc_aligned = std.mem.alignForward(u64, nhdr.n_descsz, 4);
            const next_offset = std.math.add(u64, desc_start, desc_aligned) catch return error.InvalidCoreFile;
            if (name_end > end or desc_end > end or next_offset > end) return error.InvalidCoreFile;

            const name = data[offset..name_end];
            const is_core_owner = name.len == 5 and std.mem.eql(u8, name, "CORE\x00");
            if (nhdr.n_type == NT_PRSTATUS and is_core_owner) {
                return try parseElfPrstatus(data[desc_start..desc_end], target_arch);
            }

            offset = next_offset;
        }

        return null;
    }

    fn parseElfPrstatus(desc: []const u8, target_arch: std.Target.Cpu.Arch) !RegisterState {
        // Linux ELF64 elf_prstatus places pr_reg at byte 112 for both supported
        // ABIs, but the register set size and order are architecture-specific.
        const register_offset: usize = switch (target_arch) {
            .x86_64, .aarch64 => 112,
            else => return error.UnsupportedArchitecture,
        };
        const register_size: usize = switch (target_arch) {
            .x86_64 => 27 * @sizeOf(u64),
            .aarch64 => 34 * @sizeOf(u64),
            else => return error.UnsupportedArchitecture,
        };
        if (desc.len < register_offset + register_size) return error.InvalidCoreFile;
        const regs_data = desc[register_offset..][0..register_size];

        var state = RegisterState{};
        switch (target_arch) {
            .x86_64 => {
                // Linux x86_64 user_regs_struct kernel order mapped to the
                // platform-neutral DWARF order documented by RegisterState.
                state.gprs[15] = readRegister(regs_data, 0); // r15
                state.gprs[14] = readRegister(regs_data, 1); // r14
                state.gprs[13] = readRegister(regs_data, 2); // r13
                state.gprs[12] = readRegister(regs_data, 3); // r12
                state.gprs[6] = readRegister(regs_data, 4); // rbp
                state.gprs[3] = readRegister(regs_data, 5); // rbx
                state.gprs[11] = readRegister(regs_data, 6); // r11
                state.gprs[10] = readRegister(regs_data, 7); // r10
                state.gprs[9] = readRegister(regs_data, 8); // r9
                state.gprs[8] = readRegister(regs_data, 9); // r8
                state.gprs[0] = readRegister(regs_data, 10); // rax
                state.gprs[2] = readRegister(regs_data, 11); // rcx
                state.gprs[1] = readRegister(regs_data, 12); // rdx
                state.gprs[4] = readRegister(regs_data, 13); // rsi
                state.gprs[5] = readRegister(regs_data, 14); // rdi
                state.pc = readRegister(regs_data, 16); // rip
                state.flags = readRegister(regs_data, 18); // eflags
                state.gprs[7] = readRegister(regs_data, 19); // rsp
                state.fp = state.gprs[6];
                state.sp = state.gprs[7];
            },
            .aarch64 => {
                for (0..31) |index| state.gprs[index] = readRegister(regs_data, index);
                state.sp = readRegister(regs_data, 31);
                state.pc = readRegister(regs_data, 32);
                state.flags = readRegister(regs_data, 33);
                state.fp = state.gprs[29];
            },
            else => return error.UnsupportedArchitecture,
        }
        return state;
    }

    fn readRegister(data: []const u8, index: usize) u64 {
        return std.mem.readInt(u64, data[index * 8 ..][0..8], .little);
    }

    // ── Mach-O Core Parsing ─────────────────────────────────────────

    const MachHeader64 = extern struct {
        magic: u32,
        cputype: i32,
        cpusubtype: i32,
        filetype: u32,
        ncmds: u32,
        sizeofcmds: u32,
        flags: u32,
        reserved: u32,
    };

    const SegmentCommand64 = extern struct {
        cmd: u32,
        cmdsize: u32,
        segname: [16]u8,
        vmaddr: u64,
        vmsize: u64,
        fileoff: u64,
        filesize: u64,
        maxprot: i32,
        initprot: i32,
        nsects: u32,
        flags: u32,
    };

    const MH_CORE: u32 = 4;
    const LC_SEGMENT_64: u32 = 0x19;
    const LC_THREAD: u32 = 0x5;

    fn parseMachOCore(allocator: std.mem.Allocator, data: []const u8) !CoreDump {
        if (data.len < @sizeOf(MachHeader64)) return error.InvalidCoreFile;

        const header = std.mem.bytesAsValue(MachHeader64, data[0..@sizeOf(MachHeader64)]);
        if (header.filetype != MH_CORE) return error.InvalidCoreFile;

        var segments = std.ArrayListUnmanaged(Segment){};
        errdefer segments.deinit(allocator);
        var registers = RegisterState{};
        var found_regs = false;

        var offset: u64 = @sizeOf(MachHeader64);
        var cmd_i: u32 = 0;
        while (cmd_i < header.ncmds) : (cmd_i += 1) {
            if (offset + 8 > data.len) break;
            const cmd = std.mem.readInt(u32, data[offset..][0..4], .little);
            const cmdsize = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
            if (cmdsize < 8 or offset + cmdsize > data.len) break;

            if (cmd == LC_SEGMENT_64 and offset + @sizeOf(SegmentCommand64) <= data.len) {
                const seg = std.mem.bytesAsValue(SegmentCommand64, data[offset..][0..@sizeOf(SegmentCommand64)]);
                if (seg.filesize > 0) {
                    try segments.append(allocator, .{
                        .vaddr = seg.vmaddr,
                        .file_offset = seg.fileoff,
                        .file_size = seg.filesize,
                        .mem_size = seg.vmsize,
                    });
                }
            } else if (cmd == LC_THREAD and !found_regs) {
                // LC_THREAD contains thread state: flavor(u32) + count(u32) + register data
                const thread_data_offset = offset + 8; // skip cmd + cmdsize
                const thread_data_end = offset + cmdsize;
                if (parseMachOThreadState(data, thread_data_offset, thread_data_end)) |regs| {
                    registers = regs;
                    found_regs = true;
                }
            }

            offset += cmdsize;
        }

        return .{
            .data = data,
            .segments = try segments.toOwnedSlice(allocator),
            .registers = registers,
            .allocator = allocator,
        };
    }

    fn parseMachOThreadState(data: []const u8, start: u64, end: u64) ?RegisterState {
        var offset = start;

        while (offset + 8 <= end and offset + 8 <= data.len) {
            const flavor = std.mem.readInt(u32, data[offset..][0..4], .little);
            const count = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little); // count in u32 units
            offset += 8;

            const state_size: u64 = @as(u64, count) * 4;
            if (offset + state_size > data.len) return null;

            if (builtin.cpu.arch == .aarch64) {
                // ARM_THREAD_STATE64 flavor = 6
                if (flavor == 6 and state_size >= 33 * 8 + 4) {
                    var state = RegisterState{};
                    const reg_data = data[offset..];
                    for (0..29) |i| {
                        state.gprs[i] = std.mem.readInt(u64, reg_data[i * 8 ..][0..8], .little);
                    }
                    state.fp = std.mem.readInt(u64, reg_data[29 * 8 ..][0..8], .little); // x29/fp
                    state.gprs[30] = std.mem.readInt(u64, reg_data[30 * 8 ..][0..8], .little); // lr
                    state.sp = std.mem.readInt(u64, reg_data[31 * 8 ..][0..8], .little);
                    state.pc = std.mem.readInt(u64, reg_data[32 * 8 ..][0..8], .little);
                    state.gprs[29] = state.fp;
                    return state;
                }
            } else if (builtin.cpu.arch == .x86_64) {
                // x86_THREAD_STATE64 flavor = 4
                if (flavor == 4 and state_size >= 21 * 8) {
                    var state = RegisterState{};
                    const reg_data = data[offset..];
                    // x86_thread_state64 layout:
                    // rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp, r8-r15, rip, rflags, cs, fs, gs
                    state.gprs[0] = std.mem.readInt(u64, reg_data[0..8], .little); // rax
                    state.gprs[3] = std.mem.readInt(u64, reg_data[8..16], .little); // rbx
                    state.gprs[1] = std.mem.readInt(u64, reg_data[16..24], .little); // rcx
                    state.gprs[2] = std.mem.readInt(u64, reg_data[24..32], .little); // rdx
                    state.gprs[5] = std.mem.readInt(u64, reg_data[32..40], .little); // rdi
                    state.gprs[4] = std.mem.readInt(u64, reg_data[40..48], .little); // rsi
                    state.fp = std.mem.readInt(u64, reg_data[48..56], .little); // rbp
                    state.sp = std.mem.readInt(u64, reg_data[56..64], .little); // rsp
                    state.gprs[8] = std.mem.readInt(u64, reg_data[64..72], .little); // r8
                    state.gprs[9] = std.mem.readInt(u64, reg_data[72..80], .little); // r9
                    state.gprs[10] = std.mem.readInt(u64, reg_data[80..88], .little); // r10
                    state.gprs[11] = std.mem.readInt(u64, reg_data[88..96], .little); // r11
                    state.gprs[12] = std.mem.readInt(u64, reg_data[96..104], .little); // r12
                    state.gprs[13] = std.mem.readInt(u64, reg_data[104..112], .little); // r13
                    state.gprs[14] = std.mem.readInt(u64, reg_data[112..120], .little); // r14
                    state.gprs[15] = std.mem.readInt(u64, reg_data[120..128], .little); // r15
                    state.pc = std.mem.readInt(u64, reg_data[128..136], .little); // rip
                    state.flags = std.mem.readInt(u64, reg_data[136..144], .little); // rflags
                    return state;
                }
            }

            offset += state_size;
        }

        return null;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "CoreDump.readMemory returns data from matching segment" {
    const allocator = std.testing.allocator;

    // Build a fake CoreDump with one segment
    const data = try allocator.alloc(u8, 256);
    defer allocator.free(data);
    @memset(data, 0);
    // Write known pattern at file offset 64
    data[64] = 0xDE;
    data[65] = 0xAD;
    data[66] = 0xBE;
    data[67] = 0xEF;

    const segments = try allocator.alloc(CoreDump.Segment, 1);
    defer allocator.free(segments);
    segments[0] = .{
        .vaddr = 0x1000,
        .file_offset = 64,
        .file_size = 128,
        .mem_size = 128,
    };

    var cd = CoreDump{
        .data = data,
        .segments = segments,
        .registers = .{},
        .allocator = allocator,
    };
    // Don't call deinit since we manually manage memory in this test
    _ = &cd;

    const result = try cd.readMemory(0x1000, 4, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(u8, 0xDE), result[0]);
    try std.testing.expectEqual(@as(u8, 0xAD), result[1]);
    try std.testing.expectEqual(@as(u8, 0xBE), result[2]);
    try std.testing.expectEqual(@as(u8, 0xEF), result[3]);
}

test "CoreDump.readMemory returns error for unmapped address" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 64);
    defer allocator.free(data);
    @memset(data, 0);

    var cd = CoreDump{
        .data = data,
        .segments = &.{},
        .registers = .{},
        .allocator = allocator,
    };
    _ = &cd;

    try std.testing.expectError(error.AddressNotMapped, cd.readMemory(0x1000, 4, allocator));
}

test "CoreDump.readRegisters returns stored state" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 16);
    defer allocator.free(data);

    var expected = RegisterState{};
    expected.pc = 0xDEADBEEF;
    expected.sp = 0xCAFEBABE;

    var cd = CoreDump{
        .data = data,
        .segments = &.{},
        .registers = expected,
        .allocator = allocator,
    };
    _ = &cd;

    const regs = cd.readRegisters();
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), regs.pc);
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE), regs.sp);
}

fn writeTestNoteHeader(data: []u8, namesz: u32, descsz: u32, note_type: u32) void {
    std.mem.writeInt(u32, data[0..4], namesz, .little);
    std.mem.writeInt(u32, data[4..8], descsz, .little);
    std.mem.writeInt(u32, data[8..12], note_type, .little);
}

fn writeTestU64(data: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, data[offset..][0..8], value, .little);
}

test "ELF x86_64 PRSTATUS maps kernel registers to DWARF slots" {
    var note: [384]u8 = [_]u8{0} ** 384;
    writeTestNoteHeader(&note, 5, 336, CoreDump.NT_PRSTATUS);
    @memcpy(note[12..17], "CORE\x00");

    const desc_start = 20;
    const regs_start = desc_start + 112;
    for (0..27) |index| writeTestU64(&note, regs_start + index * 8, 0x100 + index);

    const state = (try CoreDump.parseElfNotes(&note, 0, 356, .x86_64)).?;
    try std.testing.expectEqual(@as(u64, 0x10A), state.gprs[0]); // rax
    try std.testing.expectEqual(@as(u64, 0x10C), state.gprs[1]); // rdx
    try std.testing.expectEqual(@as(u64, 0x10B), state.gprs[2]); // rcx
    try std.testing.expectEqual(@as(u64, 0x105), state.gprs[3]); // rbx
    try std.testing.expectEqual(@as(u64, 0x10D), state.gprs[4]); // rsi
    try std.testing.expectEqual(@as(u64, 0x10E), state.gprs[5]); // rdi
    try std.testing.expectEqual(@as(u64, 0x104), state.gprs[6]); // rbp
    try std.testing.expectEqual(@as(u64, 0x113), state.gprs[7]); // rsp
    try std.testing.expectEqual(@as(u64, 0x110), state.pc); // rip
    try std.testing.expectEqual(@as(u64, 0x112), state.flags); // eflags
    try std.testing.expectEqual(state.gprs[6], state.fp);
    try std.testing.expectEqual(state.gprs[7], state.sp);
}

test "ELF aarch64 PRSTATUS uses architecture register offset" {
    var note: [416]u8 = [_]u8{0} ** 416;
    writeTestNoteHeader(&note, 5, 392, CoreDump.NT_PRSTATUS);
    @memcpy(note[12..17], "CORE\x00");

    const desc_start = 20;
    const regs_start = desc_start + 112;
    for (0..34) |index| writeTestU64(&note, regs_start + index * 8, 0x200 + index);

    const state = (try CoreDump.parseElfNotes(&note, 0, 412, .aarch64)).?;
    try std.testing.expectEqual(@as(u64, 0x200), state.gprs[0]);
    try std.testing.expectEqual(@as(u64, 0x21E), state.gprs[30]);
    try std.testing.expectEqual(@as(u64, 0x21F), state.sp);
    try std.testing.expectEqual(@as(u64, 0x220), state.pc);
    try std.testing.expectEqual(@as(u64, 0x221), state.flags);
    try std.testing.expectEqual(state.gprs[29], state.fp);
}

test "ELF notes ignore non-CORE NT_PRSTATUS owners" {
    var note: [384]u8 = [_]u8{0} ** 384;
    writeTestNoteHeader(&note, 4, 336, CoreDump.NT_PRSTATUS);
    @memcpy(note[12..16], "GNU\x00");

    try std.testing.expect((try CoreDump.parseElfNotes(&note, 0, 352, .x86_64)) == null);
}

test "ELF notes reject descriptors extending beyond the note segment" {
    var note: [384]u8 = [_]u8{0} ** 384;
    writeTestNoteHeader(&note, 5, 336, CoreDump.NT_PRSTATUS);
    @memcpy(note[12..17], "CORE\x00");

    try std.testing.expectError(
        error.InvalidCoreFile,
        CoreDump.parseElfNotes(&note, 0, 128, .x86_64),
    );
}

test "ELF notes reject truncated headers" {
    const note = [_]u8{0} ** 11;
    try std.testing.expectError(
        error.InvalidCoreFile,
        CoreDump.parseElfNotes(&note, 0, note.len, .x86_64),
    );
}

test "ELF notes reject aligned name extending beyond segment" {
    var note: [16]u8 = [_]u8{0} ** 16;
    writeTestNoteHeader(&note, 5, 0, CoreDump.NT_PRSTATUS);
    try std.testing.expectError(
        error.InvalidCoreFile,
        CoreDump.parseElfNotes(&note, 0, note.len, .x86_64),
    );
}

test "ELF notes skip unrelated types before PRSTATUS" {
    var notes: [416]u8 = [_]u8{0} ** 416;
    writeTestNoteHeader(notes[0..], 5, 4, 3);
    @memcpy(notes[12..17], "CORE\x00");

    const second = 24;
    writeTestNoteHeader(notes[second..], 5, 336, CoreDump.NT_PRSTATUS);
    @memcpy(notes[second + 12 .. second + 17], "CORE\x00");
    const regs_start = second + 20 + 112;
    writeTestU64(&notes, regs_start + 16 * 8, 0xABCD);

    const state = (try CoreDump.parseElfNotes(&notes, 0, 380, .x86_64)).?;
    try std.testing.expectEqual(@as(u64, 0xABCD), state.pc);
}

test "ELF notes reject unsupported register architecture" {
    var note: [384]u8 = [_]u8{0} ** 384;
    writeTestNoteHeader(&note, 5, 336, CoreDump.NT_PRSTATUS);
    @memcpy(note[12..17], "CORE\x00");
    try std.testing.expectError(
        error.UnsupportedArchitecture,
        CoreDump.parseElfNotes(&note, 0, 356, .riscv64),
    );
}
