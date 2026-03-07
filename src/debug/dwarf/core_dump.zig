const std = @import("std");
const builtin = @import("builtin");
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
        const file = try std.fs.cwd().openFile(core_path, .{});
        defer file.close();

        const stat = try file.stat();
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

    fn parseElfCore(allocator: std.mem.Allocator, data: []const u8) !CoreDump {
        if (data.len < 64) return error.InvalidCoreFile; // ELF64 header is 64 bytes

        // Verify ELF64 and ET_CORE
        const ei_class = data[4];
        if (ei_class != 2) return error.InvalidCoreFile; // Must be 64-bit

        const e_type = std.mem.readInt(u16, data[16..18], .little);
        if (e_type != ET_CORE) return error.InvalidCoreFile;

        const e_phoff = std.mem.readInt(u64, data[32..40], .little);
        const e_phentsize = std.mem.readInt(u16, data[54..56], .little);
        const e_phnum = std.mem.readInt(u16, data[56..58], .little);

        var segments = std.ArrayListUnmanaged(Segment){};
        errdefer segments.deinit(allocator);
        var registers = RegisterState{};
        var found_regs = false;

        var i: u16 = 0;
        while (i < e_phnum) : (i += 1) {
            const ph_offset = e_phoff + @as(u64, i) * @as(u64, e_phentsize);
            if (ph_offset + @sizeOf(Elf64Phdr) > data.len) break;

            const phdr = std.mem.bytesAsValue(Elf64Phdr, data[ph_offset..][0..@sizeOf(Elf64Phdr)]);

            if (phdr.p_type == PT_LOAD) {
                try segments.append(allocator, .{
                    .vaddr = phdr.p_vaddr,
                    .file_offset = phdr.p_offset,
                    .file_size = phdr.p_filesz,
                    .mem_size = phdr.p_memsz,
                });
            } else if (phdr.p_type == PT_NOTE and !found_regs) {
                // Parse NOTE segment for NT_PRSTATUS
                if (parseElfNotes(data, phdr.p_offset, phdr.p_filesz)) |regs| {
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

    fn parseElfNotes(data: []const u8, note_offset: u64, note_size: u64) ?RegisterState {
        var offset = note_offset;
        const end = note_offset + note_size;

        while (offset + @sizeOf(Elf64Nhdr) <= end and offset + @sizeOf(Elf64Nhdr) <= data.len) {
            const nhdr = std.mem.bytesAsValue(Elf64Nhdr, data[offset..][0..@sizeOf(Elf64Nhdr)]);
            offset += @sizeOf(Elf64Nhdr);

            // Skip name (aligned to 4 bytes)
            const name_aligned = std.mem.alignForward(u64, nhdr.n_namesz, 4);
            offset += name_aligned;

            if (nhdr.n_type == NT_PRSTATUS) {
                // prstatus layout varies by arch. The register set starts at a fixed
                // offset within the struct:
                //   x86_64: siginfo(12) + padding(4) + signal(8) + ... registers at offset 112
                //   aarch64: siginfo(12) + padding(4) + signal(8) + ... registers at offset 112
                const desc_start = offset;
                const desc_end = desc_start + nhdr.n_descsz;
                if (desc_end > data.len) return null;

                // x86_64 prstatus: general-purpose registers start at offset 112
                // aarch64 prstatus: registers start at offset 112
                const reg_offset: u64 = 112;
                const reg_start = desc_start + reg_offset;

                if (builtin.cpu.arch == .x86_64) {
                    // x86_64: user_regs_struct has 27 u64 fields
                    // Order: r15,r14,r13,r12,rbp,rbx,r11,r10,r9,r8,rax,rcx,rdx,rsi,rdi,
                    //         orig_rax,rip,cs,eflags,rsp,ss,fs_base,gs_base,ds,es,fs,gs
                    if (reg_start + 27 * 8 > data.len) return null;
                    const regs_data = data[reg_start..];

                    var state = RegisterState{};
                    // Map kernel register order to our RegisterState
                    state.gprs[12] = std.mem.readInt(u64, regs_data[0..8], .little); // r12 <- pos 4 is wrong, let me fix
                    // Correct x86_64 user_regs_struct order:
                    // 0:r15, 1:r14, 2:r13, 3:r12, 4:rbp, 5:rbx, 6:r11, 7:r10
                    // 8:r9, 9:r8, 10:rax, 11:rcx, 12:rdx, 13:rsi, 14:rdi
                    // 15:orig_rax, 16:rip, 17:cs, 18:eflags, 19:rsp, 20:ss
                    state.gprs[15] = std.mem.readInt(u64, regs_data[0..8], .little); // r15
                    state.gprs[14] = std.mem.readInt(u64, regs_data[8..16], .little); // r14
                    state.gprs[13] = std.mem.readInt(u64, regs_data[16..24], .little); // r13
                    state.gprs[12] = std.mem.readInt(u64, regs_data[24..32], .little); // r12
                    state.fp = std.mem.readInt(u64, regs_data[32..40], .little); // rbp
                    state.gprs[3] = std.mem.readInt(u64, regs_data[40..48], .little); // rbx
                    state.gprs[11] = std.mem.readInt(u64, regs_data[48..56], .little); // r11
                    state.gprs[10] = std.mem.readInt(u64, regs_data[56..64], .little); // r10
                    state.gprs[9] = std.mem.readInt(u64, regs_data[64..72], .little); // r9
                    state.gprs[8] = std.mem.readInt(u64, regs_data[72..80], .little); // r8
                    state.gprs[0] = std.mem.readInt(u64, regs_data[80..88], .little); // rax
                    state.gprs[1] = std.mem.readInt(u64, regs_data[88..96], .little); // rcx -> rdx mapping note: kernel order is rcx at 11
                    state.gprs[2] = std.mem.readInt(u64, regs_data[96..104], .little); // rdx
                    state.gprs[4] = std.mem.readInt(u64, regs_data[104..112], .little); // rsi -> but engine maps rsi=4
                    state.gprs[5] = std.mem.readInt(u64, regs_data[112..120], .little); // rdi -> engine maps rdi=5
                    // orig_rax at 15*8 = 120, skip
                    state.pc = std.mem.readInt(u64, regs_data[128..136], .little); // rip
                    state.flags = std.mem.readInt(u64, regs_data[144..152], .little); // eflags
                    state.sp = std.mem.readInt(u64, regs_data[152..160], .little); // rsp

                    return state;
                } else if (builtin.cpu.arch == .aarch64) {
                    // aarch64: 31 general registers (x0-x30) + sp + pc + pstate
                    if (reg_start + 34 * 8 > data.len) return null;
                    const regs_data = data[reg_start..];

                    var state = RegisterState{};
                    for (0..31) |gi| {
                        state.gprs[gi] = std.mem.readInt(u64, regs_data[gi * 8 ..][0..8], .little);
                    }
                    state.sp = std.mem.readInt(u64, regs_data[31 * 8 ..][0..8], .little);
                    state.pc = std.mem.readInt(u64, regs_data[32 * 8 ..][0..8], .little);
                    state.flags = std.mem.readInt(u64, regs_data[33 * 8 ..][0..8], .little);
                    state.fp = state.gprs[29]; // x29 is frame pointer on aarch64

                    return state;
                }
            }

            // Skip desc (aligned to 4 bytes)
            const desc_aligned = std.mem.alignForward(u64, nhdr.n_descsz, 4);
            offset += desc_aligned;
        }

        return null;
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
