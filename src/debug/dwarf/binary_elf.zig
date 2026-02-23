const std = @import("std");
const builtin = @import("builtin");
const binary_macho = @import("binary_macho.zig");

// ── ELF Binary Format Loading ──────────────────────────────────────────

const DebugSections = binary_macho.DebugSections;

// ELF format constants
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };
const ELFCLASS32: u8 = 1;
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;
const SHF_COMPRESSED: u64 = 0x800;

const SectionInfo = binary_macho.SectionInfo;
const CompressionKind = binary_macho.CompressionKind;

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

pub const ElfBinary = struct {
    data: []const u8,
    owned: bool,
    sections: DebugSections,
    decompressed_buffers: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !ElfBinary {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            allocator.free(data);
            return error.IncompleteRead;
        }

        var result = try parseElf(data);
        result.owned = true;
        return result;
    }

    pub fn loadFromMemory(data: []const u8) !ElfBinary {
        return parseElf(data);
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
        return parseElf32(data);
    } else if (elf_class == ELFCLASS64) {
        return parseElf64(data);
    } else {
        return error.UnsupportedFormat;
    }
}

fn parseElf32(data: []const u8) !ElfBinary {
    if (data.len < @sizeOf(Elf32Header)) return error.TooSmall;

    const header = readStruct(Elf32Header, data, 0) catch return error.TooSmall;

    var sections = DebugSections{};

    if (header.e_shstrndx == 0 or header.e_shnum == 0) {
        return .{ .data = data, .owned = false, .sections = sections };
    }

    const shstrtab_offset = @as(u64, header.e_shoff) + @as(u64, header.e_shstrndx) * @as(u64, header.e_shentsize);
    const shstrtab_hdr = readStruct(Elf32SectionHeader, data, @intCast(shstrtab_offset)) catch {
        return .{ .data = data, .owned = false, .sections = sections };
    };

    const strtab_start: usize = @intCast(shstrtab_hdr.sh_offset);
    const strtab_end = strtab_start + @as(usize, @intCast(shstrtab_hdr.sh_size));
    if (strtab_end > data.len) {
        return .{ .data = data, .owned = false, .sections = sections };
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
        };
        if (shdr.sh_flags & @as(u32, @truncate(SHF_COMPRESSED)) != 0) {
            info.compression = .shf_compressed_32;
        }

        matchDebugSection(name, info, &sections);
    }

    return .{
        .data = data,
        .owned = false,
        .sections = sections,
    };
}

fn parseElf64(data: []const u8) !ElfBinary {
    if (data.len < @sizeOf(Elf64Header)) return error.TooSmall;

    const header = readStruct(Elf64Header, data, 0) catch return error.TooSmall;

    var sections = DebugSections{};

    if (header.e_shstrndx == 0 or header.e_shnum == 0) {
        return .{ .data = data, .owned = false, .sections = sections };
    }

    const shstrtab_offset = header.e_shoff + @as(u64, header.e_shstrndx) * @as(u64, header.e_shentsize);
    const shstrtab_hdr = readStruct(Elf64SectionHeader, data, @intCast(shstrtab_offset)) catch {
        return .{ .data = data, .owned = false, .sections = sections };
    };

    const strtab_start: usize = @intCast(shstrtab_hdr.sh_offset);
    const strtab_end = strtab_start + @as(usize, @intCast(shstrtab_hdr.sh_size));
    if (strtab_end > data.len) {
        return .{ .data = data, .owned = false, .sections = sections };
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
        };
        if (shdr.sh_flags & SHF_COMPRESSED != 0) {
            info.compression = .shf_compressed_64;
        }

        matchDebugSection(name, info, &sections);
    }

    return .{
        .data = data,
        .owned = false,
        .sections = sections,
    };
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
    return .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
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
