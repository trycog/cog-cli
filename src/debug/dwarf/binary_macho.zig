const std = @import("std");
const builtin = @import("builtin");
const debug_log = @import("../../debug_log.zig");

// ── Mach-O Binary Format Loading ───────────────────────────────────────

// Mach-O format constants
const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x02;
const N_OSO: u8 = 0x66;

const SymtabCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    symoff: u32,
    nsyms: u32,
    stroff: u32,
    strsize: u32,
};

const Nlist64 = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: u16,
    n_value: u64,
};

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
        debug_log.log("dwarf.macho: loading binary {s}", .{path});
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            debug_log.log("dwarf.macho: incomplete read for {s}, expected {d} got {d}", .{ path, stat.size, bytes_read });
            allocator.free(data);
            return error.IncompleteRead;
        }

        var result = try parseMachO(data);
        result.owned = true;
        debug_log.log("dwarf.macho: loaded {s}, size={d}, has_debug_info={}", .{ path, stat.size, result.sections.hasDebugInfo() });
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
    if (header.magic != MH_MAGIC_64) {
        debug_log.log("dwarf.macho: invalid magic 0x{x}", .{header.magic});
        return error.InvalidMagic;
    }
    debug_log.log("dwarf.macho: parsing Mach-O, ncmds={d}", .{header.ncmds});

    var sections = DebugSections{};
    var text_vmaddr: u64 = 0;
    var offset: usize = @sizeOf(MachHeader64);

    for (0..header.ncmds) |_| {
        if (offset + 8 > data.len) break;

        const cmd = std.mem.readInt(u32, data[offset..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);

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

    debug_log.log("dwarf.macho: sections found: debug_info={} debug_line={} debug_abbrev={} debug_str={} text_vmaddr=0x{x}", .{
        sections.debug_info != null,
        sections.debug_line != null,
        sections.debug_abbrev != null,
        sections.debug_str != null,
        text_vmaddr,
    });

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

// ── N_OSO Object File Path Extraction ────────────────────────────────────

/// Extract unique object file paths from N_OSO stab entries in a Mach-O binary.
/// On macOS, when a binary is compiled without dsymutil, DWARF debug info remains
/// in the individual .o files. The symbol table contains N_OSO stab entries pointing
/// to those object files. Returns an owned slice of owned path strings.
pub fn extractObjectFilePaths(allocator: std.mem.Allocator, data: []const u8) ![][]const u8 {
    const empty: [][]const u8 = &.{};
    if (data.len < @sizeOf(MachHeader64)) return empty;

    const header = readStruct(MachHeader64, data, 0) catch return empty;
    if (header.magic != MH_MAGIC_64) {
        debug_log.log("dwarf.macho.noso: invalid magic 0x{x}", .{header.magic});
        return empty;
    }

    // Scan load commands for LC_SYMTAB
    var offset: usize = @sizeOf(MachHeader64);
    var symtab_cmd: ?SymtabCommand = null;

    for (0..header.ncmds) |_| {
        if (offset + 8 > data.len) break;

        const cmd = std.mem.readInt(u32, data[offset..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);

        if (cmdsize < 8) break;

        if (cmd == LC_SYMTAB and offset + @sizeOf(SymtabCommand) <= data.len) {
            symtab_cmd = readStruct(SymtabCommand, data, offset) catch null;
            break;
        }

        offset += cmdsize;
    }

    const symtab = symtab_cmd orelse {
        debug_log.log("dwarf.macho.noso: LC_SYMTAB not found", .{});
        return empty;
    };

    debug_log.log("dwarf.macho.noso: LC_SYMTAB found, nsyms={d}, symoff={d}, stroff={d}", .{ symtab.nsyms, symtab.symoff, symtab.stroff });

    const nlist_size = @sizeOf(Nlist64);
    const sym_end = @as(usize, symtab.symoff) + @as(usize, symtab.nsyms) * nlist_size;
    if (sym_end > data.len or @as(usize, symtab.stroff) >= data.len) {
        debug_log.log("dwarf.macho.noso: symbol table or string table extends past end of data", .{});
        return empty;
    }

    // Use a hash map for deduplication
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var paths = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (paths.items) |p| allocator.free(@constCast(p));
        paths.deinit(allocator);
    }

    var noso_count: usize = 0;
    for (0..symtab.nsyms) |i| {
        const entry_offset = @as(usize, symtab.symoff) + i * nlist_size;
        if (entry_offset + nlist_size > data.len) break;

        const nlist = readStruct(Nlist64, data, entry_offset) catch continue;

        if (nlist.n_type != N_OSO) continue;

        noso_count += 1;

        // Read the string from the string table
        const str_start = @as(usize, symtab.stroff) + @as(usize, nlist.n_strx);
        if (str_start >= data.len) continue;

        // Find null terminator
        var str_end = str_start;
        while (str_end < data.len and data[str_end] != 0) : (str_end += 1) {}
        if (str_end == str_start) continue;

        const path = data[str_start..str_end];

        // Deduplicate
        if (seen.contains(path)) continue;

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        try seen.put(owned_path, {});
        try paths.append(allocator, owned_path);

        debug_log.log("dwarf.macho.noso: found object file: {s}", .{owned_path});
    }

    debug_log.log("dwarf.macho.noso: scanned {d} symbols, found {d} N_OSO entries, {d} unique object files", .{ symtab.nsyms, noso_count, paths.items.len });

    return try paths.toOwnedSlice(allocator);
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

test "extractObjectFilePaths returns empty for binary without symtab" {
    var data = [_]u8{0} ** @sizeOf(MachHeader64);
    std.mem.writeInt(u32, data[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, data[16..20], 0, .little); // ncmds = 0
    const paths = try extractObjectFilePaths(std.testing.allocator, &data);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "extractObjectFilePaths extracts and deduplicates N_OSO paths" {
    // Build a minimal Mach-O with an LC_SYMTAB containing N_OSO entries
    const header_size = @sizeOf(MachHeader64);
    const symtab_cmd_size = @sizeOf(SymtabCommand);
    const nlist_size = @sizeOf(Nlist64);
    const num_syms = 3; // Two entries pointing to same path, one to different

    // String table: "\x00/tmp/a.o\x00/tmp/b.o\x00"
    const str_table = "\x00/tmp/a.o\x00/tmp/b.o\x00";
    const str_table_len = str_table.len;

    const symoff = header_size + symtab_cmd_size;
    const stroff = symoff + num_syms * nlist_size;
    const total_size = stroff + str_table_len;

    var data = [_]u8{0} ** total_size;

    // Mach-O header
    std.mem.writeInt(u32, data[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, data[16..20], 1, .little); // ncmds = 1

    // LC_SYMTAB command
    const cmd_off = header_size;
    std.mem.writeInt(u32, data[cmd_off..][0..4], LC_SYMTAB, .little); // cmd
    std.mem.writeInt(u32, data[cmd_off + 4 ..][0..4], @intCast(symtab_cmd_size), .little); // cmdsize
    std.mem.writeInt(u32, data[cmd_off + 8 ..][0..4], @intCast(symoff), .little); // symoff
    std.mem.writeInt(u32, data[cmd_off + 12 ..][0..4], num_syms, .little); // nsyms
    std.mem.writeInt(u32, data[cmd_off + 16 ..][0..4], @intCast(stroff), .little); // stroff
    std.mem.writeInt(u32, data[cmd_off + 20 ..][0..4], @intCast(str_table_len), .little); // strsize

    // nlist entries (each 16 bytes: n_strx[4] n_type[1] n_sect[1] n_desc[2] n_value[8])
    // Entry 0: N_OSO pointing to "/tmp/a.o" (str index 1)
    const e0 = symoff;
    std.mem.writeInt(u32, data[e0..][0..4], 1, .little); // n_strx = 1 -> "/tmp/a.o"
    data[e0 + 4] = N_OSO; // n_type

    // Entry 1: N_OSO pointing to "/tmp/a.o" again (duplicate)
    const e1 = symoff + nlist_size;
    std.mem.writeInt(u32, data[e1..][0..4], 1, .little); // n_strx = 1 -> "/tmp/a.o"
    data[e1 + 4] = N_OSO; // n_type

    // Entry 2: N_OSO pointing to "/tmp/b.o" (str index 10)
    const e2 = symoff + 2 * nlist_size;
    std.mem.writeInt(u32, data[e2..][0..4], 10, .little); // n_strx = 10 -> "/tmp/b.o"
    data[e2 + 4] = N_OSO; // n_type

    // Copy string table
    @memcpy(data[stroff..][0..str_table_len], str_table);

    const paths = try extractObjectFilePaths(std.testing.allocator, &data);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    // Should have 2 unique paths (deduplicated)
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/tmp/a.o", paths[0]);
    try std.testing.expectEqualStrings("/tmp/b.o", paths[1]);
}

test "extractObjectFilePaths ignores non-N_OSO symbols" {
    const header_size = @sizeOf(MachHeader64);
    const symtab_cmd_size = @sizeOf(SymtabCommand);
    const nlist_size = @sizeOf(Nlist64);
    const num_syms = 2;

    const str_table = "\x00/tmp/a.o\x00_main\x00";
    const str_table_len = str_table.len;

    const symoff = header_size + symtab_cmd_size;
    const stroff = symoff + num_syms * nlist_size;
    const total_size = stroff + str_table_len;

    var data = [_]u8{0} ** total_size;

    // Mach-O header
    std.mem.writeInt(u32, data[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, data[16..20], 1, .little); // ncmds = 1

    // LC_SYMTAB command
    const cmd_off = header_size;
    std.mem.writeInt(u32, data[cmd_off..][0..4], LC_SYMTAB, .little);
    std.mem.writeInt(u32, data[cmd_off + 4 ..][0..4], @intCast(symtab_cmd_size), .little);
    std.mem.writeInt(u32, data[cmd_off + 8 ..][0..4], @intCast(symoff), .little);
    std.mem.writeInt(u32, data[cmd_off + 12 ..][0..4], num_syms, .little);
    std.mem.writeInt(u32, data[cmd_off + 16 ..][0..4], @intCast(stroff), .little);
    std.mem.writeInt(u32, data[cmd_off + 20 ..][0..4], @intCast(str_table_len), .little);

    // Entry 0: N_OSO pointing to "/tmp/a.o"
    const e0 = symoff;
    std.mem.writeInt(u32, data[e0..][0..4], 1, .little);
    data[e0 + 4] = N_OSO;

    // Entry 1: Regular symbol (n_type = 0x0F, not N_OSO)
    const e1 = symoff + nlist_size;
    std.mem.writeInt(u32, data[e1..][0..4], 10, .little); // points to "_main"
    data[e1 + 4] = 0x0F; // some non-N_OSO type

    // Copy string table
    @memcpy(data[stroff..][0..str_table_len], str_table);

    const paths = try extractObjectFilePaths(std.testing.allocator, &data);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    // Should only have the N_OSO path
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("/tmp/a.o", paths[0]);
}
