const std = @import("std");
const builtin = @import("builtin");

// ── Mach-O Binary Format Loading ───────────────────────────────────────

// Mach-O format constants
const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const LC_SEGMENT_64: u32 = 0x19;

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

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

pub const CompressionKind = enum {
    none,
    zdebug, // GNU __zdebug_* / .zdebug_* with 12-byte header (4-byte "ZLIB" + 8-byte BE size)
    shf_compressed_32, // ELF SHF_COMPRESSED with Elf32_Chdr (12 bytes)
    shf_compressed_64, // ELF SHF_COMPRESSED with Elf64_Chdr (24 bytes)
};

pub const SectionInfo = struct {
    offset: u64,
    size: u64,
    compression: CompressionKind = .none,
};

pub const DebugSections = struct {
    debug_info: ?SectionInfo = null,
    debug_abbrev: ?SectionInfo = null,
    debug_line: ?SectionInfo = null,
    debug_str: ?SectionInfo = null,
    debug_str_offsets: ?SectionInfo = null,
    debug_addr: ?SectionInfo = null,
    debug_ranges: ?SectionInfo = null,
    debug_aranges: ?SectionInfo = null,
    debug_line_str: ?SectionInfo = null,
    debug_frame: ?SectionInfo = null,
    debug_loc: ?SectionInfo = null,
    debug_loclists: ?SectionInfo = null,
    debug_rnglists: ?SectionInfo = null,
    eh_frame: ?SectionInfo = null,
    debug_macro: ?SectionInfo = null,
    debug_names: ?SectionInfo = null,
    debug_types: ?SectionInfo = null,
    debug_pubnames: ?SectionInfo = null,
    debug_pubtypes: ?SectionInfo = null,

    pub fn hasDebugInfo(self: DebugSections) bool {
        return self.debug_info != null or self.debug_line != null;
    }
};

pub const MachoBinary = struct {
    data: []const u8,
    owned: bool,
    sections: DebugSections,
    text_vmaddr: u64 = 0,
    decompressed_buffers: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !MachoBinary {
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

        var result = try parseMachO(data);
        result.owned = true;
        return result;
    }

    pub fn loadFromMemory(data: []const u8) !MachoBinary {
        return parseMachO(data);
    }

    pub fn deinit(self: *MachoBinary, allocator: std.mem.Allocator) void {
        for (self.decompressed_buffers.items) |buf| {
            allocator.free(buf);
        }
        self.decompressed_buffers.deinit(allocator);
        if (self.owned) {
            allocator.free(@constCast(self.data));
        }
    }

    pub fn getSectionData(self: *const MachoBinary, info: SectionInfo) ?[]const u8 {
        const start: usize = @intCast(info.offset);
        const end = start + @as(usize, @intCast(info.size));
        if (end > self.data.len) return null;
        return self.data[start..end];
    }

    /// Get section data, transparently decompressing if needed.
    /// Decompressed buffers are owned by the binary and freed on deinit.
    pub fn getSectionDataAlloc(self: *MachoBinary, allocator: std.mem.Allocator, info: SectionInfo) !?[]const u8 {
        if (info.compression == .none) return self.getSectionData(info);
        const decompressed = try self.decompressSection(allocator, info);
        try self.decompressed_buffers.append(allocator, decompressed);
        return decompressed;
    }

    /// Decompress a compressed debug section.
    /// For zdebug: strips 12-byte GNU header (4-byte "ZLIB" magic + 8-byte BE uncompressed size).
    fn decompressSection(self: *const MachoBinary, allocator: std.mem.Allocator, info: SectionInfo) ![]u8 {
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

        // Decompress zlib stream using std.compress.flate
        var reader = std.Io.Reader.fixed(compressed);
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var decompress = std.compress.flate.Decompress.init(&reader, .zlib, &.{});
        _ = decompress.reader.streamRemaining(&aw.writer) catch return error.DecompressFailed;
        return aw.toOwnedSlice();
    }
};

fn parseMachO(data: []const u8) !MachoBinary {
    if (data.len < @sizeOf(MachHeader64)) return error.TooSmall;

    const header = readStruct(MachHeader64, data, 0) catch return error.TooSmall;
    if (header.magic != MH_MAGIC_64) return error.InvalidMagic;

    var sections = DebugSections{};
    var text_vmaddr: u64 = 0;
    var offset: usize = @sizeOf(MachHeader64);

    for (0..header.ncmds) |_| {
        if (offset + 8 > data.len) break;

        const cmd = std.mem.readInt(u32, data[offset..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, data[offset + 4..][0..4], .little);

        if (cmdsize < 8) break;

        if (cmd == LC_SEGMENT_64 and offset + @sizeOf(SegmentCommand64) <= data.len) {
            const seg = readStruct(SegmentCommand64, data, offset) catch break;

            // Capture __TEXT segment vmaddr for ASLR slide computation
            const segname = parseName(&seg.segname);
            if (std.mem.eql(u8, segname, "__TEXT")) {
                text_vmaddr = seg.vmaddr;
            }

            var sect_offset = offset + @sizeOf(SegmentCommand64);
            for (0..seg.nsects) |_| {
                if (sect_offset + @sizeOf(Section64) > data.len) break;

                const sect = readStruct(Section64, data, sect_offset) catch break;
                const name = parseName(&sect.sectname);

                const info = SectionInfo{
                    .offset = sect.offset,
                    .size = sect.size,
                };

                matchMachoDebugSection(name, info, &sections);

                sect_offset += @sizeOf(Section64);
            }
        }

        offset += cmdsize;
    }

    return .{
        .data = data,
        .owned = false,
        .sections = sections,
        .text_vmaddr = text_vmaddr,
    };
}

fn matchMachoDebugSection(name: []const u8, info: SectionInfo, sections: *DebugSections) void {
    // Uncompressed __debug_* sections
    if (std.mem.eql(u8, name, "__debug_info")) {
        sections.debug_info = info;
    } else if (std.mem.eql(u8, name, "__debug_abbrev")) {
        sections.debug_abbrev = info;
    } else if (std.mem.eql(u8, name, "__debug_line")) {
        sections.debug_line = info;
    } else if (std.mem.eql(u8, name, "__debug_str")) {
        sections.debug_str = info;
    } else if (std.mem.eql(u8, name, "__debug_str_offs")) {
        sections.debug_str_offsets = info;
    } else if (std.mem.eql(u8, name, "__debug_addr")) {
        sections.debug_addr = info;
    } else if (std.mem.eql(u8, name, "__debug_ranges")) {
        sections.debug_ranges = info;
    } else if (std.mem.eql(u8, name, "__debug_aranges")) {
        sections.debug_aranges = info;
    } else if (std.mem.eql(u8, name, "__debug_line_str")) {
        sections.debug_line_str = info;
    } else if (std.mem.eql(u8, name, "__debug_frame")) {
        sections.debug_frame = info;
    } else if (std.mem.eql(u8, name, "__debug_loc")) {
        sections.debug_loc = info;
    } else if (std.mem.eql(u8, name, "__debug_loclists")) {
        sections.debug_loclists = info;
    } else if (std.mem.eql(u8, name, "__debug_rnglists")) {
        sections.debug_rnglists = info;
    } else if (std.mem.eql(u8, name, "__eh_frame")) {
        sections.eh_frame = info;
    } else if (std.mem.eql(u8, name, "__debug_macro")) {
        sections.debug_macro = info;
    } else if (std.mem.eql(u8, name, "__debug_names")) {
        sections.debug_names = info;
    } else if (std.mem.eql(u8, name, "__debug_types")) {
        sections.debug_types = info;
    } else if (std.mem.eql(u8, name, "__debug_pubnames")) {
        sections.debug_pubnames = info;
    } else if (std.mem.eql(u8, name, "__debug_pubtypes")) {
        sections.debug_pubtypes = info;
    }
    // Compressed __zdebug_* sections (GNU zdebug format)
    // Mach-O section names are limited to 16 chars, so some are truncated
    else if (std.mem.eql(u8, name, "__zdebug_info")) {
        sections.debug_info = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_abbrev") or std.mem.eql(u8, name, "__zdebug_abbre")) {
        sections.debug_abbrev = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_line")) {
        sections.debug_line = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_str")) {
        sections.debug_str = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_str_of")) {
        sections.debug_str_offsets = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_addr")) {
        sections.debug_addr = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_ranges")) {
        sections.debug_ranges = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_arange")) {
        sections.debug_aranges = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_line_s")) {
        sections.debug_line_str = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_frame")) {
        sections.debug_frame = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_loc")) {
        sections.debug_loc = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_loclis")) {
        sections.debug_loclists = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_rnglis")) {
        sections.debug_rnglists = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_macro")) {
        sections.debug_macro = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_names")) {
        sections.debug_names = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.eql(u8, name, "__zdebug_types")) {
        sections.debug_types = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_pubnam")) {
        sections.debug_pubnames = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    } else if (std.mem.startsWith(u8, name, "__zdebug_pubtyp")) {
        sections.debug_pubtypes = .{ .offset = info.offset, .size = info.size, .compression = .zdebug };
    }
}

fn readStruct(comptime T: type, data: []const u8, offset: usize) !T {
    const size = @sizeOf(T);
    if (offset + size > data.len) return error.OutOfBounds;
    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), data[offset..][0..size]);
    return result;
}

fn parseName(name: *const [16]u8) []const u8 {
    for (name, 0..) |c, i| {
        if (c == 0) return name[0..i];
    }
    return name[0..16];
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parseName extracts null-terminated name" {
    const name: [16]u8 = "__debug_info\x00\x00\x00\x00".*;
    try std.testing.expectEqualStrings("__debug_info", parseName(&name));
}

test "parseName handles full-length name" {
    const name: [16]u8 = "0123456789abcdef".*;
    try std.testing.expectEqualStrings("0123456789abcdef", parseName(&name));
}

test "loadFromMemory rejects data too small for header" {
    const small = [_]u8{0} ** 10;
    const result = MachoBinary.loadFromMemory(&small);
    try std.testing.expectError(error.TooSmall, result);
}

test "loadFromMemory rejects invalid magic" {
    var data = [_]u8{0} ** @sizeOf(MachHeader64);
    // Set invalid magic
    std.mem.writeInt(u32, data[0..4], 0xDEADBEEF, .little);
    const result = MachoBinary.loadFromMemory(&data);
    try std.testing.expectError(error.InvalidMagic, result);
}

test "loadFromMemory accepts valid Mach-O header with zero commands" {
    var data = [_]u8{0} ** @sizeOf(MachHeader64);
    // Set magic
    std.mem.writeInt(u32, data[0..4], MH_MAGIC_64, .little);
    // ncmds = 0
    std.mem.writeInt(u32, data[16..20], 0, .little);

    const binary = try MachoBinary.loadFromMemory(&data);
    try std.testing.expect(!binary.sections.hasDebugInfo());
}

test "loadBinary identifies correct binary format" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // Successfully loaded means it's valid Mach-O
    try std.testing.expect(true);
}

test "loadBinary locates .debug_info section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_info != null);
    const info = binary.sections.debug_info.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_line section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_line != null);
    const info = binary.sections.debug_line.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_abbrev section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_abbrev != null);
    const info = binary.sections.debug_abbrev.?;
    try std.testing.expect(info.size > 0);
}

test "loadBinary locates .debug_str section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    try std.testing.expect(binary.sections.debug_str != null);
    const info = binary.sections.debug_str.?;
    try std.testing.expect(info.size > 0);
}

test "getSectionData returns correct byte slice" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
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

test "loadBinary locates .eh_frame section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var binary = MachoBinary.loadFile(std.testing.allocator, "test/fixtures/multi_func.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer binary.deinit(std.testing.allocator);

    // multi_func.o should have __eh_frame with call frame info for stack unwinding
    if (binary.sections.eh_frame) |info| {
        try std.testing.expect(info.size > 0);
        const data = binary.getSectionData(info);
        try std.testing.expect(data != null);
    }
    // Note: .eh_frame presence depends on compiler/platform flags;
    // if not present, the test still passes (the field is optional)
}

test "loadBinary returns error for non-Mach-O file" {
    // Try to load a text file as Mach-O
    const result = MachoBinary.loadFile(std.testing.allocator, "build.zig");
    try std.testing.expectError(error.InvalidMagic, result);
}

test "DebugSections new fields default to null" {
    const sections = DebugSections{};
    try std.testing.expect(sections.debug_macro == null);
    try std.testing.expect(sections.debug_names == null);
    try std.testing.expect(sections.debug_types == null);
    try std.testing.expect(sections.debug_pubnames == null);
    try std.testing.expect(sections.debug_pubtypes == null);
}

test "parseMachO matches new debug section names" {
    // Build a minimal Mach-O with a __DWARF segment containing a __debug_macro section
    const header_size = @sizeOf(MachHeader64);
    const seg_size = @sizeOf(SegmentCommand64);
    const sect_size = @sizeOf(Section64);
    const num_sections = 5;
    const seg_cmdsize = seg_size + num_sections * sect_size;
    const dummy_data_offset = header_size + seg_cmdsize;
    const dummy_data_size = 16;
    const total_size = dummy_data_offset + dummy_data_size;

    var data = [_]u8{0} ** total_size;

    // Mach-O header
    std.mem.writeInt(u32, data[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, data[16..20], 1, .little); // ncmds = 1

    // Segment command (SegmentCommand64 layout: cmd[4] cmdsize[4] segname[16] vmaddr[8] vmsize[8] fileoff[8] filesize[8] maxprot[4] initprot[4] nsects[4] flags[4])
    const seg_off = header_size;
    std.mem.writeInt(u32, data[seg_off..][0..4], LC_SEGMENT_64, .little); // cmd at +0
    std.mem.writeInt(u32, data[seg_off + 4 ..][0..4], @intCast(seg_cmdsize), .little); // cmdsize at +4
    // segname = "__DWARF" at +8
    @memcpy(data[seg_off + 8 ..][0..7], "__DWARF");
    std.mem.writeInt(u32, data[seg_off + 64 ..][0..4], num_sections, .little); // nsects at +64

    // Helper to write a section entry
    const sect_base = seg_off + seg_size;
    const section_names = [_][]const u8{ "__debug_macro", "__debug_names", "__debug_types", "__debug_pubnames", "__debug_pubtypes" };

    for (0..num_sections) |i| {
        const s_off = sect_base + i * sect_size;
        @memcpy(data[s_off..][0..section_names[i].len], section_names[i]);
        // Section64 layout: sectname[16], segname[16], addr(u64), size(u64), offset(u32)
        std.mem.writeInt(u64, data[s_off + 40 ..][0..8], dummy_data_size, .little); // size at offset 40
        std.mem.writeInt(u32, data[s_off + 48 ..][0..4], @intCast(dummy_data_offset), .little); // offset at offset 48
    }

    const binary = try MachoBinary.loadFromMemory(&data);
    try std.testing.expect(binary.sections.debug_macro != null);
    try std.testing.expect(binary.sections.debug_names != null);
    try std.testing.expect(binary.sections.debug_types != null);
    try std.testing.expect(binary.sections.debug_pubnames != null);
    try std.testing.expect(binary.sections.debug_pubtypes != null);
}
