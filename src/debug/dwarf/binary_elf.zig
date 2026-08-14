const std = @import("std");
const builtin = @import("builtin");
const binary_common = @import("binary.zig");
const debug_log = @import("../../debug_log.zig");

// ── ELF Binary Format Loading ──────────────────────────────────────────

const DebugSections = binary_common.DebugSections;

// ELF format constants
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };
const ELFCLASS32: u8 = 1;
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;
const SHF_COMPRESSED: u64 = 0x800;
const PT_LOAD: u32 = 1;

const SectionInfo = binary_common.SectionInfo;
const CompressionKind = binary_common.CompressionKind;

const Elf32Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf32SectionHeader = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u32,
    sh_addr: u32,
    sh_offset: u32,
    sh_size: u32,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u32,
    sh_entsize: u32,
};

const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64SectionHeader = extern struct {
    sh_name: u32,
    sh_type: u32,
    sh_flags: u64,
    sh_addr: u64,
    sh_offset: u64,
    sh_size: u64,
    sh_link: u32,
    sh_info: u32,
    sh_addralign: u64,
    sh_entsize: u64,
};

const Elf32ProgramHeader = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

const Elf64ProgramHeader = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const ElfBinary = struct {
    data: []const u8,
    owned: bool,
    sections: DebugSections,
    preferred_base: u64 = 0,
    // Defaults to the strict relocatable assumption; parseElf records the
    // real ELF type so fixed-address (ET_EXEC) cores can accept a zero bias.
    is_pie: bool = true,
    decompressed_buffers: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !ElfBinary {
        debug_log.log("dwarf.elf: loading binary {s}", .{path});
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            debug_log.log("dwarf.elf: incomplete read for {s}, expected {d} got {d}", .{ path, stat.size, bytes_read });
            allocator.free(data);
            return error.IncompleteRead;
        }

        var result = try parseElf(data);
        result.owned = true;
        debug_log.log("dwarf.elf: loaded {s}, size={d}, preferred_base=0x{x} has_debug_info={}", .{ path, stat.size, result.preferred_base, result.sections.hasDebugInfo() });
        return result;
    }

    pub fn loadFromMemory(data: []const u8) !ElfBinary {
        return parseElf(data);
    }

    /// Return a format-neutral binary view for DWARF section consumers.
    pub fn view(self: *ElfBinary) binary_common.Binary {
        return .init(
            .elf,
            @ptrCast(self),
            &self.sections,
            self.preferred_base,
            viewGetSectionData,
            viewGetSectionDataAlloc,
        );
    }

    fn viewGetSectionData(context: *anyopaque, info: SectionInfo) ?[]const u8 {
        const self: *ElfBinary = @ptrCast(@alignCast(context));
        return self.getSectionData(info);
    }

    fn viewGetSectionDataAlloc(context: *anyopaque, allocator: std.mem.Allocator, info: SectionInfo) !?[]const u8 {
        const self: *ElfBinary = @ptrCast(@alignCast(context));
        return self.getSectionDataAlloc(allocator, info);
    }

    pub fn deinit(self: *ElfBinary, allocator: std.mem.Allocator) void {
        for (self.decompressed_buffers.items) |buf| {
            allocator.free(buf);
        }
        self.decompressed_buffers.deinit(allocator);
        if (self.owned) {
            allocator.free(@constCast(self.data));
        }
    }

    /// Compute the signed relocation from the preferred image base to its runtime base.
    pub fn loadBias(self: ElfBinary, runtime_base: u64) i64 {
        const runtime: i128 = runtime_base;
        const preferred: i128 = self.preferred_base;
        return @intCast(runtime - preferred);
    }

    pub fn getSectionData(self: *const ElfBinary, info: SectionInfo) ?[]const u8 {
        const start: usize = @intCast(info.offset);
        const end = start + @as(usize, @intCast(info.size));
        if (end > self.data.len) return null;
        return self.data[start..end];
    }

    /// Get section data, transparently decompressing if needed.
    pub fn getSectionDataAlloc(self: *ElfBinary, allocator: std.mem.Allocator, info: SectionInfo) !?[]const u8 {
        if (info.compression == .none) return self.getSectionData(info);
        const decompressed = try self.decompressSection(allocator, info);
        try self.decompressed_buffers.append(allocator, decompressed);
        return decompressed;
    }

    /// Decompress a compressed debug section.
    fn decompressSection(self: *const ElfBinary, allocator: std.mem.Allocator, info: SectionInfo) ![]u8 {
        const raw = self.getSectionData(.{ .offset = info.offset, .size = info.size }) orelse return error.NoSectionData;

        const header_size: usize = switch (info.compression) {
            .zdebug => 12, // "ZLIB" + 8-byte BE size
            .shf_compressed_64 => 24, // Elf64_Chdr
            .shf_compressed_32 => 12, // Elf32_Chdr
            .none => return error.NotCompressed,
        };

        if (raw.len < header_size) return error.InvalidCompressedSection;

        // Validate header
        if (info.compression == .zdebug) {
            if (!std.mem.eql(u8, raw[0..4], "ZLIB")) return error.InvalidCompressedSection;
        }

        const compressed = raw[header_size..];

        var reader = std.Io.Reader.fixed(compressed);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var decompress = std.compress.flate.Decompress.init(&reader, .zlib, &.{});
        _ = decompress.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;
        return aw.toOwnedSlice();
    }
};

fn parseElf(data: []const u8) !ElfBinary {
    // Minimum check: at least 16 bytes for e_ident
    if (data.len < 16) return error.TooSmall;

    // Validate ELF magic
    if (!std.mem.eql(u8, data[0..4], &ELF_MAGIC)) return error.InvalidMagic;
    if (data[5] != ELFDATA2LSB) return error.UnsupportedFormat;

    const elf_class = data[4];
    if (elf_class == ELFCLASS32) {
        var result = try parseElf32(data);
        result.is_pie = elfTypeIsPie(data);
        return result;
    } else if (elf_class == ELFCLASS64) {
        var result = try parseElf64(data);
        result.is_pie = elfTypeIsPie(data);
        return result;
    } else {
        return error.UnsupportedFormat;
    }
}

/// Only ET_DYN images relocate at load time; ET_EXEC executables map at their
/// link-time addresses, so a zero load bias is valid for them.
fn elfTypeIsPie(data: []const u8) bool {
    const ET_DYN: u16 = 3;
    if (data.len < 18) return true;
    return std.mem.readInt(u16, data[16..18], .little) == ET_DYN;
}

test "ELF type detection distinguishes fixed-address executables" {
    var header: [18]u8 = [_]u8{0} ** 18;
    std.mem.writeInt(u16, header[16..18], 2, .little); // ET_EXEC
    try std.testing.expect(!elfTypeIsPie(&header));
    std.mem.writeInt(u16, header[16..18], 3, .little); // ET_DYN
    try std.testing.expect(elfTypeIsPie(&header));
}

fn parseElf32(data: []const u8) !ElfBinary {
    if (data.len < @sizeOf(Elf32Header)) return error.TooSmall;

    const header = readStruct(Elf32Header, data, 0) catch return error.TooSmall;

    var sections = DebugSections{};
    const preferred_base = preferredBase32(data, header);

    if (header.e_shstrndx == 0 or header.e_shnum == 0) {
        return .{ .data = data, .owned = false, .sections = sections, .preferred_base = preferred_base };
    }

    const shstrtab_offset = @as(u64, header.e_shoff) + @as(u64, header.e_shstrndx) * @as(u64, header.e_shentsize);
    const shstrtab_hdr = readStruct(Elf32SectionHeader, data, @intCast(shstrtab_offset)) catch {
        return .{ .data = data, .owned = false, .sections = sections, .preferred_base = preferred_base };
    };

    const strtab_start: usize = @intCast(shstrtab_hdr.sh_offset);
    const strtab_end = strtab_start + @as(usize, @intCast(shstrtab_hdr.sh_size));
    if (strtab_end > data.len) {
        return .{ .data = data, .owned = false, .sections = sections, .preferred_base = preferred_base };
    }
    const strtab = data[strtab_start..strtab_end];

    for (0..header.e_shnum) |i| {
        const sh_offset = @as(u64, header.e_shoff) + @as(u64, @intCast(i)) * @as(u64, header.e_shentsize);
        const shdr = readStruct(Elf32SectionHeader, data, @intCast(sh_offset)) catch continue;

        const name = readStringFromTable(strtab, shdr.sh_name);
        if (name.len == 0) continue;

        var info = SectionInfo{
            .offset = @as(u64, shdr.sh_offset),
            .size = @as(u64, shdr.sh_size),
            .virtual_address = @as(u64, shdr.sh_addr),
        };
        if (shdr.sh_flags & @as(u32, @truncate(SHF_COMPRESSED)) != 0) {
            info.compression = .shf_compressed_32;
        }

        matchDebugSection(name, info, &sections);
    }

    debug_log.log("dwarf.elf: parsed ELF32 preferred_base=0x{x} debug_info={} eh_frame={}", .{ preferred_base, sections.debug_info != null, sections.eh_frame != null });
    return .{
        .data = data,
        .owned = false,
        .sections = sections,
        .preferred_base = preferred_base,
    };
}

fn parseElf64(data: []const u8) !ElfBinary {
    if (data.len < @sizeOf(Elf64Header)) return error.TooSmall;

    const header = readStruct(Elf64Header, data, 0) catch return error.TooSmall;

    var sections = DebugSections{};
    const preferred_base = preferredBase64(data, header);

    if (header.e_shstrndx == 0 or header.e_shnum == 0) {
        return .{ .data = data, .owned = false, .sections = sections, .preferred_base = preferred_base };
    }

    const shstrtab_offset = header.e_shoff + @as(u64, header.e_shstrndx) * @as(u64, header.e_shentsize);
    const shstrtab_hdr = readStruct(Elf64SectionHeader, data, @intCast(shstrtab_offset)) catch {
        return .{ .data = data, .owned = false, .sections = sections, .preferred_base = preferred_base };
    };

    const strtab_start: usize = @intCast(shstrtab_hdr.sh_offset);
    const strtab_end = strtab_start + @as(usize, @intCast(shstrtab_hdr.sh_size));
    if (strtab_end > data.len) {
        return .{ .data = data, .owned = false, .sections = sections, .preferred_base = preferred_base };
    }
    const strtab = data[strtab_start..strtab_end];

    for (0..header.e_shnum) |i| {
        const sh_offset = header.e_shoff + @as(u64, @intCast(i)) * @as(u64, header.e_shentsize);
        const shdr = readStruct(Elf64SectionHeader, data, @intCast(sh_offset)) catch continue;

        const name = readStringFromTable(strtab, shdr.sh_name);
        if (name.len == 0) continue;

        var info = SectionInfo{
            .offset = shdr.sh_offset,
            .size = shdr.sh_size,
            .virtual_address = shdr.sh_addr,
        };
        if (shdr.sh_flags & SHF_COMPRESSED != 0) {
            info.compression = .shf_compressed_64;
        }

        matchDebugSection(name, info, &sections);
    }

    debug_log.log("dwarf.elf: parsed ELF64 preferred_base=0x{x} debug_info={} eh_frame={}", .{ preferred_base, sections.debug_info != null, sections.eh_frame != null });
    return .{
        .data = data,
        .owned = false,
        .sections = sections,
        .preferred_base = preferred_base,
    };
}

fn preferredBase32(data: []const u8, header: Elf32Header) u64 {
    var preferred: ?u64 = null;
    if (header.e_phentsize < @sizeOf(Elf32ProgramHeader)) return 0;
    for (0..header.e_phnum) |i| {
        const offset = @as(u64, header.e_phoff) + @as(u64, @intCast(i)) * @as(u64, header.e_phentsize);
        const phdr = readStruct(Elf32ProgramHeader, data, @intCast(offset)) catch continue;
        if (phdr.p_type != PT_LOAD) continue;
        const alignment = if (phdr.p_align > 1) phdr.p_align else 1;
        const base = @as(u64, phdr.p_vaddr) -% (@as(u64, phdr.p_offset) % alignment);
        preferred = if (preferred) |current| @min(current, base) else base;
    }
    return preferred orelse 0;
}

fn preferredBase64(data: []const u8, header: Elf64Header) u64 {
    var preferred: ?u64 = null;
    if (header.e_phentsize < @sizeOf(Elf64ProgramHeader)) return 0;
    for (0..header.e_phnum) |i| {
        const offset = header.e_phoff + @as(u64, @intCast(i)) * @as(u64, header.e_phentsize);
        const phdr = readStruct(Elf64ProgramHeader, data, @intCast(offset)) catch continue;
        if (phdr.p_type != PT_LOAD) continue;
        const alignment = if (phdr.p_align > 1) phdr.p_align else 1;
        const base = phdr.p_vaddr -% (phdr.p_offset % alignment);
        preferred = if (preferred) |current| @min(current, base) else base;
    }
    return preferred orelse 0;
}

fn matchDebugSection(name: []const u8, info: SectionInfo, sections: *DebugSections) void {
    // Uncompressed .debug_* sections
    if (std.mem.eql(u8, name, ".debug_info")) {
        sections.debug_info = info;
    } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
        sections.debug_abbrev = info;
    } else if (std.mem.eql(u8, name, ".debug_line")) {
        sections.debug_line = info;
    } else if (std.mem.eql(u8, name, ".debug_str")) {
        sections.debug_str = info;
    } else if (std.mem.eql(u8, name, ".debug_ranges")) {
        sections.debug_ranges = info;
    } else if (std.mem.eql(u8, name, ".debug_aranges")) {
        sections.debug_aranges = info;
    } else if (std.mem.eql(u8, name, ".debug_line_str")) {
        sections.debug_line_str = info;
    } else if (std.mem.eql(u8, name, ".debug_frame")) {
        sections.debug_frame = info;
    } else if (std.mem.eql(u8, name, ".debug_loc")) {
        sections.debug_loc = info;
    } else if (std.mem.eql(u8, name, ".debug_loclists")) {
        sections.debug_loclists = info;
    } else if (std.mem.eql(u8, name, ".debug_rnglists")) {
        sections.debug_rnglists = info;
    } else if (std.mem.eql(u8, name, ".eh_frame")) {
        sections.eh_frame = info;
    } else if (std.mem.eql(u8, name, ".debug_str_offsets")) {
        sections.debug_str_offsets = info;
    } else if (std.mem.eql(u8, name, ".debug_addr")) {
        sections.debug_addr = info;
    } else if (std.mem.eql(u8, name, ".debug_macro")) {
        sections.debug_macro = info;
    } else if (std.mem.eql(u8, name, ".debug_names")) {
        sections.debug_names = info;
    } else if (std.mem.eql(u8, name, ".debug_types")) {
        sections.debug_types = info;
    } else if (std.mem.eql(u8, name, ".debug_pubnames")) {
        sections.debug_pubnames = info;
    } else if (std.mem.eql(u8, name, ".debug_pubtypes")) {
        sections.debug_pubtypes = info;
    }
    // Compressed .zdebug_* sections (GNU zdebug format)
    else if (std.mem.eql(u8, name, ".zdebug_info")) {
        sections.debug_info = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_abbrev")) {
        sections.debug_abbrev = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_line")) {
        sections.debug_line = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_str")) {
        sections.debug_str = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_ranges")) {
        sections.debug_ranges = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_aranges")) {
        sections.debug_aranges = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_line_str")) {
        sections.debug_line_str = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_frame")) {
        sections.debug_frame = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_loc")) {
        sections.debug_loc = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_loclists")) {
        sections.debug_loclists = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_rnglists")) {
        sections.debug_rnglists = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_str_offsets")) {
        sections.debug_str_offsets = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_addr")) {
        sections.debug_addr = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_macro")) {
        sections.debug_macro = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_names")) {
        sections.debug_names = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_types")) {
        sections.debug_types = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_pubnames")) {
        sections.debug_pubnames = zdebugInfo(info);
    } else if (std.mem.eql(u8, name, ".zdebug_pubtypes")) {
        sections.debug_pubtypes = zdebugInfo(info);
    }
    // Split DWARF / debug fission (.dwo suffixed sections)
    else if (std.mem.eql(u8, name, ".debug_info.dwo")) {
        sections.debug_info = info;
    } else if (std.mem.eql(u8, name, ".debug_abbrev.dwo")) {
        sections.debug_abbrev = info;
    } else if (std.mem.eql(u8, name, ".debug_str.dwo")) {
        sections.debug_str = info;
    } else if (std.mem.eql(u8, name, ".debug_str_offsets.dwo")) {
        sections.debug_str_offsets = info;
    } else if (std.mem.eql(u8, name, ".debug_line.dwo")) {
        sections.debug_line = info;
    } else if (std.mem.eql(u8, name, ".debug_loc.dwo")) {
        sections.debug_loc = info;
    } else if (std.mem.eql(u8, name, ".debug_loclists.dwo")) {
        sections.debug_loclists = info;
    } else if (std.mem.eql(u8, name, ".debug_macro.dwo")) {
        sections.debug_macro = info;
    } else if (std.mem.eql(u8, name, ".debug_rnglists.dwo")) {
        sections.debug_rnglists = info;
    }
}

/// Create a SectionInfo with zdebug compression from an existing info.
/// If the section was also marked SHF_COMPRESSED, zdebug takes precedence
/// since the section name determines the format.
fn zdebugInfo(info: SectionInfo) SectionInfo {
    return .{
        .offset = info.offset,
        .size = info.size,
        .virtual_address = info.virtual_address,
        .compression = .zdebug,
    };
}

fn readStruct(comptime T: type, data: []const u8, offset: usize) !T {
    const size = @sizeOf(T);
    if (offset + size > data.len) return error.OutOfBounds;
    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), data[offset..][0..size]);
    return result;
}

fn readStringFromTable(table: []const u8, offset: u32) []const u8 {
    if (offset >= table.len) return "";
    const start = table[offset..];
    for (start, 0..) |c, i| {
        if (c == 0) return start[0..i];
    }
    return start;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "loadFromMemory rejects data too small for header" {
    const small = [_]u8{0} ** 10;
    const result = ElfBinary.loadFromMemory(&small);
    try std.testing.expectError(error.TooSmall, result);
}

test "loadFromMemory rejects invalid magic" {
    var data = [_]u8{0} ** @sizeOf(Elf64Header);
    data[0] = 0xDE;
    data[1] = 0xAD;
    const result = ElfBinary.loadFromMemory(&data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "loadFromMemory accepts 32-bit ELF" {
    var data = [_]u8{0} ** @sizeOf(Elf64Header);
    // Set ELF magic
    data[0] = 0x7f;
    data[1] = 'E';
    data[2] = 'L';
    data[3] = 'F';
    data[4] = 1; // ELFCLASS32 - now supported
    data[5] = ELFDATA2LSB;
    // Should succeed with empty sections (no section headers)
    const elf = try ElfBinary.loadFromMemory(&data);
    try std.testing.expect(elf.sections.debug_info == null);
}

test "loadFromMemory accepts valid ELF header with zero sections" {
    var data = [_]u8{0} ** @sizeOf(Elf64Header);
    data[0] = 0x7f;
    data[1] = 'E';
    data[2] = 'L';
    data[3] = 'F';
    data[4] = ELFCLASS64;
    data[5] = ELFDATA2LSB;

    const binary = try ElfBinary.loadFromMemory(&data);
    try std.testing.expect(!binary.sections.hasDebugInfo());
}

test "readStringFromTable extracts null-terminated string" {
    const table = ".debug_info\x00.debug_line\x00";
    const name = readStringFromTable(table, 0);
    try std.testing.expectEqualStrings(".debug_info", name);
}

test "readStringFromTable extracts string at offset" {
    const table = ".debug_info\x00.debug_line\x00";
    const name = readStringFromTable(table, 12);
    try std.testing.expectEqualStrings(".debug_line", name);
}

test "readStringFromTable returns empty for out-of-bounds offset" {
    const table = "test\x00";
    const name = readStringFromTable(table, 100);
    try std.testing.expectEqualStrings("", name);
}

test "loadBinary returns error for non-ELF file" {
    const result = ElfBinary.loadFile(std.testing.allocator, "build.zig");
    try std.testing.expectError(error.InvalidMagic, result);
}

test "loadBinary identifies correct binary format" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // Successfully loaded means it's valid ELF
    try std.testing.expect(true);
}

test "loadBinary locates .debug_info section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_info != null);
    const info = binary.sections.debug_info.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_line section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_line != null);
    const info = binary.sections.debug_line.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_abbrev section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_abbrev != null);
    const info = binary.sections.debug_abbrev.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_str section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_str != null);
    const info = binary.sections.debug_str.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .eh_frame section" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/multi_func.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // multi_func.elf.o should have .eh_frame with call frame info for stack unwinding
    if (binary.sections.eh_frame) |info| {
        try std.testing.expect(info.size > 0);
        const data = binary.getSectionData(info);
        try std.testing.expect(data != null);
    }
}

test "getSectionData returns correct byte slice for ELF" {
    var binary = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.elf.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    if (binary.sections.debug_info) |info| {
        const data = binary.getSectionData(info);
        try std.testing.expect(data != null);
        try std.testing.expectEqual(info.size, data.?.len);
    }
}

test "parseElf loads .debug_str_offsets and .debug_addr sections" {
    // Build a minimal synthetic ELF with .debug_str_offsets and .debug_addr sections
    const header_size = @sizeOf(Elf64Header);
    const shdr_size = @sizeOf(Elf64SectionHeader);
    // String table: \0 .debug_str_offsets \0 .debug_addr \0
    const strtab = "\x00.debug_str_offsets\x00.debug_addr\x00";
    // We need 3 section headers: null, .debug_str_offsets, .debug_addr, and strtab itself
    const num_sections = 4;
    const shoff = header_size;
    const strtab_offset = shoff + num_sections * shdr_size;
    const str_offsets_offset = strtab_offset + strtab.len;
    const str_offsets_data = "STROFF"; // dummy data
    const addr_offset = str_offsets_offset + str_offsets_data.len;
    const addr_data = "ADDR"; // dummy data
    const total_size = addr_offset + addr_data.len;

    var data = [_]u8{0} ** total_size;

    // ELF header
    data[0] = 0x7f;
    data[1] = 'E';
    data[2] = 'L';
    data[3] = 'F';
    data[4] = ELFCLASS64;
    data[5] = ELFDATA2LSB;
    std.mem.writeInt(u64, data[40..48], shoff, .little); // e_shoff
    std.mem.writeInt(u16, data[58..60], shdr_size, .little); // e_shentsize
    std.mem.writeInt(u16, data[60..62], num_sections, .little); // e_shnum
    std.mem.writeInt(u16, data[62..64], 3, .little); // e_shstrndx = section 3

    // Section header 0: null (already zeroed)

    // Section header 1: .debug_str_offsets
    const sh1_off = shoff + shdr_size;
    std.mem.writeInt(u32, data[sh1_off..][0..4], 1, .little); // sh_name offset in strtab
    std.mem.writeInt(u64, data[sh1_off + 24 ..][0..8], str_offsets_offset, .little); // sh_offset
    std.mem.writeInt(u64, data[sh1_off + 32 ..][0..8], str_offsets_data.len, .little); // sh_size

    // Section header 2: .debug_addr
    const sh2_off = shoff + 2 * shdr_size;
    std.mem.writeInt(u32, data[sh2_off..][0..4], 20, .little); // sh_name offset in strtab (after ".debug_str_offsets\0")
    std.mem.writeInt(u64, data[sh2_off + 24 ..][0..8], addr_offset, .little); // sh_offset
    std.mem.writeInt(u64, data[sh2_off + 32 ..][0..8], addr_data.len, .little); // sh_size

    // Section header 3: strtab
    const sh3_off = shoff + 3 * shdr_size;
    std.mem.writeInt(u64, data[sh3_off + 24 ..][0..8], strtab_offset, .little); // sh_offset
    std.mem.writeInt(u64, data[sh3_off + 32 ..][0..8], strtab.len, .little); // sh_size

    // Copy string table data
    @memcpy(data[strtab_offset..][0..strtab.len], strtab);

    // Copy section data
    @memcpy(data[str_offsets_offset..][0..str_offsets_data.len], str_offsets_data);
    @memcpy(data[addr_offset..][0..addr_data.len], addr_data);

    const binary = try ElfBinary.loadFromMemory(&data);
    try std.testing.expect(binary.sections.debug_str_offsets != null);
    try std.testing.expect(binary.sections.debug_addr != null);
    try std.testing.expectEqual(@as(u64, str_offsets_data.len), binary.sections.debug_str_offsets.?.size);
    try std.testing.expectEqual(@as(u64, addr_data.len), binary.sections.debug_addr.?.size);
}

test "ELF64 PIE preserves load base and eh_frame virtual address" {
    const header_size = @sizeOf(Elf64Header);
    const phdr_size: usize = 56;
    const shdr_size = @sizeOf(Elf64SectionHeader);
    const num_sections = 3;
    const phoff = header_size;
    const shoff = phoff + phdr_size;
    const strtab = "\x00.eh_frame\x00.shstrtab\x00";
    const strtab_offset = shoff + num_sections * shdr_size;
    const eh_frame_offset = strtab_offset + strtab.len;
    const eh_frame_data = [_]u8{0xaa} ** 16;
    const total_size = eh_frame_offset + eh_frame_data.len;

    var data = [_]u8{0} ** total_size;
    @memcpy(data[0..4], &ELF_MAGIC);
    data[4] = ELFCLASS64;
    data[5] = ELFDATA2LSB;
    std.mem.writeInt(u16, data[16..18], 3, .little); // ET_DYN
    std.mem.writeInt(u64, data[32..40], phoff, .little);
    std.mem.writeInt(u64, data[40..48], shoff, .little);
    std.mem.writeInt(u16, data[54..56], phdr_size, .little);
    std.mem.writeInt(u16, data[56..58], 1, .little);
    std.mem.writeInt(u16, data[58..60], shdr_size, .little);
    std.mem.writeInt(u16, data[60..62], num_sections, .little);
    std.mem.writeInt(u16, data[62..64], 2, .little);

    // PT_LOAD with a non-zero preferred link-time base.
    std.mem.writeInt(u32, data[phoff..][0..4], 1, .little);
    std.mem.writeInt(u64, data[phoff + 8 ..][0..8], 0, .little);
    std.mem.writeInt(u64, data[phoff + 16 ..][0..8], 0x400000, .little);
    std.mem.writeInt(u64, data[phoff + 32 ..][0..8], total_size, .little);
    std.mem.writeInt(u64, data[phoff + 40 ..][0..8], total_size, .little);
    std.mem.writeInt(u64, data[phoff + 48 ..][0..8], 0x1000, .little);

    const eh_shoff = shoff + shdr_size;
    std.mem.writeInt(u32, data[eh_shoff..][0..4], 1, .little);
    std.mem.writeInt(u64, data[eh_shoff + 16 ..][0..8], 0x401000, .little);
    std.mem.writeInt(u64, data[eh_shoff + 24 ..][0..8], eh_frame_offset, .little);
    std.mem.writeInt(u64, data[eh_shoff + 32 ..][0..8], eh_frame_data.len, .little);

    const str_shoff = shoff + 2 * shdr_size;
    std.mem.writeInt(u32, data[str_shoff..][0..4], 11, .little);
    std.mem.writeInt(u64, data[str_shoff + 24 ..][0..8], strtab_offset, .little);
    std.mem.writeInt(u64, data[str_shoff + 32 ..][0..8], strtab.len, .little);

    @memcpy(data[strtab_offset..][0..strtab.len], strtab);
    @memcpy(data[eh_frame_offset..][0..eh_frame_data.len], &eh_frame_data);

    const binary = try ElfBinary.loadFromMemory(&data);
    try std.testing.expectEqual(@as(u64, 0x400000), binary.preferred_base);
    try std.testing.expectEqual(@as(u64, 0x401000), binary.sections.eh_frame.?.virtual_address);
    try std.testing.expectEqual(@as(i64, 0x300000), binary.loadBias(0x700000));
}

test "loadBinary returns error for non-debug ELF binary" {
    // A Mach-O object file has wrong magic for ELF
    const result = ElfBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o");
    if (result) |_| {
        // If it somehow loaded, that's unexpected for a Mach-O file
        unreachable;
    } else |err| {
        try std.testing.expect(err == error.InvalidMagic or err == error.UnsupportedFormat or err == error.FileNotFound);
    }
}

test "parseElf loads new debug sections" {
    // Build a minimal synthetic ELF with .debug_macro, .debug_names, .debug_types,
    // .debug_pubnames, and .debug_pubtypes sections
    const header_size = @sizeOf(Elf64Header);
    const shdr_size = @sizeOf(Elf64SectionHeader);
    // String table: \0 .debug_macro \0 .debug_names \0 .debug_types \0 .debug_pubnames \0 .debug_pubtypes \0
    const strtab = "\x00.debug_macro\x00.debug_names\x00.debug_types\x00.debug_pubnames\x00.debug_pubtypes\x00";
    // Section headers: null, .debug_macro, .debug_names, .debug_types, .debug_pubnames, .debug_pubtypes, strtab
    const num_sections = 7;
    const shoff = header_size;
    const strtab_offset = shoff + num_sections * shdr_size;
    const section_data_offset = strtab_offset + strtab.len;
    const section_data = "DATA"; // dummy data per section
    const total_size = section_data_offset + 5 * section_data.len;

    var data = [_]u8{0} ** total_size;

    // ELF header
    data[0] = 0x7f;
    data[1] = 'E';
    data[2] = 'L';
    data[3] = 'F';
    data[4] = ELFCLASS64;
    data[5] = ELFDATA2LSB;
    std.mem.writeInt(u64, data[40..48], shoff, .little); // e_shoff
    std.mem.writeInt(u16, data[58..60], shdr_size, .little); // e_shentsize
    std.mem.writeInt(u16, data[60..62], num_sections, .little); // e_shnum
    std.mem.writeInt(u16, data[62..64], num_sections - 1, .little); // e_shstrndx = last section

    // String table name offsets: 1, 14, 27, 40, 56
    const name_offsets = [_]u32{ 1, 14, 27, 40, 56 };

    // Section headers 1-5: the new debug sections
    for (0..5) |i| {
        const sh_off = shoff + (i + 1) * shdr_size;
        std.mem.writeInt(u32, data[sh_off..][0..4], name_offsets[i], .little); // sh_name
        std.mem.writeInt(u64, data[sh_off + 24 ..][0..8], section_data_offset + i * section_data.len, .little); // sh_offset
        std.mem.writeInt(u64, data[sh_off + 32 ..][0..8], section_data.len, .little); // sh_size
    }

    // Section header 6: strtab
    const sh_strtab_off = shoff + (num_sections - 1) * shdr_size;
    std.mem.writeInt(u64, data[sh_strtab_off + 24 ..][0..8], strtab_offset, .little); // sh_offset
    std.mem.writeInt(u64, data[sh_strtab_off + 32 ..][0..8], strtab.len, .little); // sh_size

    // Copy string table
    @memcpy(data[strtab_offset..][0..strtab.len], strtab);

    // Copy section data
    for (0..5) |i| {
        const off = section_data_offset + i * section_data.len;
        @memcpy(data[off..][0..section_data.len], section_data);
    }

    const binary = try ElfBinary.loadFromMemory(&data);
    try std.testing.expect(binary.sections.debug_macro != null);
    try std.testing.expect(binary.sections.debug_names != null);
    try std.testing.expect(binary.sections.debug_types != null);
    try std.testing.expect(binary.sections.debug_pubnames != null);
    try std.testing.expect(binary.sections.debug_pubtypes != null);

    // Verify sizes
    try std.testing.expectEqual(@as(u64, section_data.len), binary.sections.debug_macro.?.size);
    try std.testing.expectEqual(@as(u64, section_data.len), binary.sections.debug_names.?.size);
    try std.testing.expectEqual(@as(u64, section_data.len), binary.sections.debug_types.?.size);
    try std.testing.expectEqual(@as(u64, section_data.len), binary.sections.debug_pubnames.?.size);
    try std.testing.expectEqual(@as(u64, section_data.len), binary.sections.debug_pubtypes.?.size);
}
