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
