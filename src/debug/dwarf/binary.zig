//! Format-neutral metadata and address translation for native DWARF binaries.

const std = @import("std");

/// Compression applied to a debug section in the containing object format.
pub const CompressionKind = enum {
    none,
    zdebug,
    shf_compressed_32,
    shf_compressed_64,
};

/// File and virtual-address metadata for one debug section.
pub const SectionInfo = struct {
    offset: u64,
    size: u64,
    virtual_address: u64 = 0,
    compression: CompressionKind = .none,
};

/// Debug sections understood by the native DWARF engine.
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

/// Native object format backing a format-neutral binary view.
pub const Format = enum {
    macho,
    elf,

    /// Detect the supported native object format from its leading bytes.
    pub fn detect(data: []const u8) !Format {
        if (data.len < 4) return error.InvalidBinaryFormat;
        if (std.mem.eql(u8, data[0..4], "\x7fELF")) return .elf;
        if (std.mem.readInt(u32, data[0..4], .little) == 0xFEEDFACF) return .macho;
        return error.InvalidBinaryFormat;
    }
};

test "Format detection recognizes native object magic" {
    try std.testing.expectEqual(Format.elf, try Format.detect("\x7fELF"));
    try std.testing.expectEqual(Format.macho, try Format.detect("\xcf\xfa\xed\xfe"));
    try std.testing.expectError(error.InvalidBinaryFormat, Format.detect("text"));
    try std.testing.expectError(error.InvalidBinaryFormat, Format.detect(""));
}

/// Format-neutral view over native binary debug sections and image metadata.
pub const Binary = struct {
    format: Format,
    context: *anyopaque,
    sections: *const DebugSections,
    preferred_base: u64,
    get_section_data_fn: *const fn (context: *anyopaque, info: SectionInfo) ?[]const u8,
    get_section_data_alloc_fn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, info: SectionInfo) anyerror!?[]const u8,

    pub fn init(
        format: Format,
        context: *anyopaque,
        sections: *const DebugSections,
        preferred_base: u64,
        get_section_data_fn: *const fn (context: *anyopaque, info: SectionInfo) ?[]const u8,
        get_section_data_alloc_fn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, info: SectionInfo) anyerror!?[]const u8,
    ) Binary {
        return .{
            .format = format,
            .context = context,
            .sections = sections,
            .preferred_base = preferred_base,
            .get_section_data_fn = get_section_data_fn,
            .get_section_data_alloc_fn = get_section_data_alloc_fn,
        };
    }

    pub fn getSectionData(self: Binary, info: SectionInfo) ?[]const u8 {
        return self.get_section_data_fn(self.context, info);
    }

    pub fn getSectionDataAlloc(self: Binary, allocator: std.mem.Allocator, info: SectionInfo) !?[]const u8 {
        const read_alloc = self.get_section_data_alloc_fn orelse return self.getSectionData(info);
        return read_alloc(self.context, allocator, info);
    }

    pub fn loadBias(self: Binary, runtime_base: u64) i64 {
        const runtime: i128 = runtime_base;
        const preferred: i128 = self.preferred_base;
        return @intCast(runtime - preferred);
    }
};

/// Signed relocation between link-time DWARF addresses and runtime addresses.
pub const AddressTranslation = struct {
    load_bias: i64 = 0,

    /// Translate a link-time DWARF address into the runtime address space.
    pub fn dwarfToRuntime(self: AddressTranslation, address: u64) u64 {
        return applySigned(address, self.load_bias);
    }

    /// Translate a runtime address back into the link-time DWARF address space.
    pub fn runtimeToDwarf(self: AddressTranslation, address: u64) u64 {
        return applySigned(address, -self.load_bias);
    }
};

fn applySigned(address: u64, delta: i64) u64 {
    return if (delta >= 0)
        address +% @as(u64, @intCast(delta))
    else
        address -% @as(u64, @intCast(-delta));
}

test "AddressTranslation round trips zero positive and negative load biases" {
    const addresses = [_]u64{ 0, 0x1000, 0x7fff_ffff_ffff };
    const biases = [_]i64{ 0, 0x400000, -0x2000 };

    for (biases) |bias| {
        const translation = AddressTranslation{ .load_bias = bias };
        for (addresses) |address| {
            try std.testing.expectEqual(address, translation.runtimeToDwarf(translation.dwarfToRuntime(address)));
            try std.testing.expectEqual(address, translation.dwarfToRuntime(translation.runtimeToDwarf(address)));
        }
    }
}

test "SectionInfo preserves virtual address independently of file offset" {
    const section = SectionInfo{
        .offset = 0x200,
        .size = 0x80,
        .virtual_address = 0x401000,
    };
    try std.testing.expectEqual(@as(u64, 0x200), section.offset);
    try std.testing.expectEqual(@as(u64, 0x401000), section.virtual_address);
}

test "Binary view exposes format-neutral section and load APIs" {
    const Fixture = struct {
        data: []const u8,
        sections: DebugSections,

        fn read(context: *anyopaque, info: SectionInfo) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const start: usize = @intCast(info.offset);
            const end = start + @as(usize, @intCast(info.size));
            if (end > self.data.len) return null;
            return self.data[start..end];
        }
    };

    var fixture = Fixture{
        .data = "HEADdebug-tail",
        .sections = .{ .debug_info = .{ .offset = 4, .size = 5, .virtual_address = 0x401000 } },
    };
    const view = Binary.init(
        .elf,
        @ptrCast(&fixture),
        &fixture.sections,
        0x400000,
        Fixture.read,
        null,
    );

    try std.testing.expectEqual(Format.elf, view.format);
    try std.testing.expectEqual(@as(u64, 0x400000), view.preferred_base);
    try std.testing.expectEqualStrings("debug", view.getSectionData(view.sections.debug_info.?).?);
    try std.testing.expectEqual(@as(i64, 0x300000), view.loadBias(0x700000));
}
