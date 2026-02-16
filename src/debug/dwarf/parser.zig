const std = @import("std");
const builtin = @import("builtin");
const binary_macho = @import("binary_macho.zig");
const location = @import("location.zig");

// ── DWARF Debug Info Parser ────────────────────────────────────────────

// DWARF line number program opcodes
const DW_LNS_copy = 1;
const DW_LNS_advance_pc = 2;
const DW_LNS_advance_line = 3;
const DW_LNS_set_file = 4;
const DW_LNS_set_column = 5;
const DW_LNS_negate_stmt = 6;
const DW_LNS_set_basic_block = 7;
const DW_LNS_const_add_pc = 8;
const DW_LNS_fixed_advance_pc = 9;
const DW_LNS_set_prologue_end = 10;
const DW_LNS_set_epilogue_begin = 11;
const DW_LNS_set_isa = 12;

// Extended opcodes
const DW_LNE_end_sequence = 1;
const DW_LNE_set_address = 2;
const DW_LNE_define_file = 3;
const DW_LNE_set_discriminator = 4;

// Tag constants
const DW_TAG_compile_unit: u64 = 0x11;
const DW_TAG_subprogram: u64 = 0x2e;
const DW_TAG_variable: u64 = 0x34;
const DW_TAG_formal_parameter: u64 = 0x05;
const DW_TAG_base_type: u64 = 0x24;
const DW_TAG_structure_type: u64 = 0x13;
const DW_TAG_array_type: u64 = 0x01;
const DW_TAG_member: u64 = 0x0d;
const DW_TAG_subrange_type: u64 = 0x21;
const DW_TAG_pointer_type: u64 = 0x0f;
const DW_TAG_typedef: u64 = 0x16;
const DW_TAG_const_type: u64 = 0x26;
const DW_TAG_enumeration_type: u64 = 0x04;
const DW_TAG_enumerator: u64 = 0x28;
const DW_TAG_volatile_type: u64 = 0x35;
const DW_TAG_restrict_type: u64 = 0x37;
const DW_TAG_lexical_block: u64 = 0x0b;
const DW_TAG_inlined_subroutine: u64 = 0x1d;
const DW_TAG_namespace: u64 = 0x39;
const DW_TAG_unspecified_type: u64 = 0x3b;
const DW_TAG_class_type: u64 = 0x02;
const DW_TAG_union_type: u64 = 0x17;
const DW_TAG_inheritance: u64 = 0x1c;
const DW_TAG_reference_type: u64 = 0x10;
const DW_TAG_rvalue_reference_type: u64 = 0x42;
const DW_TAG_subroutine_type: u64 = 0x15;
const DW_TAG_atomic_type: u64 = 0x47;
const DW_TAG_template_type_parameter: u64 = 0x2f;
const DW_TAG_template_value_parameter: u64 = 0x30;
const DW_TAG_call_site: u64 = 0x48;
const DW_TAG_call_site_parameter: u64 = 0x49;
const DW_TAG_ptr_to_member_type: u64 = 0x1f;
const DW_TAG_interface_type: u64 = 0x38;
const DW_TAG_variant_part: u64 = 0x33;
const DW_TAG_variant: u64 = 0x19;

// Attribute constants
const DW_AT_name: u64 = 0x03;
const DW_AT_low_pc: u64 = 0x11;
const DW_AT_high_pc: u64 = 0x12;
const DW_AT_location: u64 = 0x02;
const DW_AT_type: u64 = 0x49;
const DW_AT_encoding: u64 = 0x3e;
const DW_AT_byte_size: u64 = 0x0b;
const DW_AT_data_member_location: u64 = 0x38;
const DW_AT_upper_bound: u64 = 0x2f;
const DW_AT_count: u64 = 0x37;
const DW_AT_frame_base: u64 = 0x40;
const DW_AT_const_value: u64 = 0x1c;
const DW_AT_bit_offset: u64 = 0x0c;
const DW_AT_bit_size: u64 = 0x0d;
const DW_AT_inline: u64 = 0x20;
const DW_AT_abstract_origin: u64 = 0x31;
const DW_AT_specification: u64 = 0x47;
const DW_AT_data_location: u64 = 0x50;
const DW_AT_ranges: u64 = 0x55;
const DW_AT_call_column: u64 = 0x57;
const DW_AT_call_file: u64 = 0x58;
const DW_AT_call_line: u64 = 0x59;
const DW_AT_decl_column: u64 = 0x39;
const DW_AT_decl_file: u64 = 0x3a;
const DW_AT_decl_line: u64 = 0x3b;
const DW_AT_linkage_name: u64 = 0x6e;
const DW_AT_rnglists_base: u64 = 0x74;
const DW_AT_alignment: u64 = 0x88;
const DW_AT_loclists_base: u64 = 0x8c;
const DW_AT_discr: u64 = 0x15;
const DW_AT_discr_value: u64 = 0x66;
const DW_AT_discr_list: u64 = 0x6c;
// Split DWARF / debug fission attributes
const DW_AT_dwo_name: u64 = 0x76;
const DW_AT_GNU_dwo_name: u64 = 0x2130;
const DW_AT_dwo_id: u64 = 0x42;
const DW_AT_GNU_dwo_id: u64 = 0x2131;
const DW_AT_comp_dir: u64 = 0x1b;
// DWARF unit type constants
const DW_UT_compile: u8 = 0x01;
const DW_UT_type: u8 = 0x02;
const DW_UT_partial: u8 = 0x03;
const DW_UT_skeleton: u8 = 0x04;
const DW_UT_split_compile: u8 = 0x05;
const DW_UT_split_type: u8 = 0x06;

// Form constants
const DW_FORM_addr: u64 = 0x01;
const DW_FORM_block2: u64 = 0x03;
const DW_FORM_block4: u64 = 0x04;
const DW_FORM_data2: u64 = 0x05;
const DW_FORM_data4: u64 = 0x06;
const DW_FORM_data8: u64 = 0x07;
const DW_FORM_string: u64 = 0x08;
const DW_FORM_block: u64 = 0x09;
const DW_FORM_block1: u64 = 0x0a;
const DW_FORM_data1: u64 = 0x0b;
const DW_FORM_flag: u64 = 0x0c;
const DW_FORM_sdata: u64 = 0x0d;
const DW_FORM_strp: u64 = 0x0e;
const DW_FORM_udata: u64 = 0x0f;
const DW_FORM_ref_addr: u64 = 0x10;
const DW_FORM_ref1: u64 = 0x11;
const DW_FORM_ref2: u64 = 0x12;
const DW_FORM_ref4: u64 = 0x13;
const DW_FORM_ref8: u64 = 0x14;
const DW_FORM_ref_udata: u64 = 0x15;
const DW_FORM_indirect: u64 = 0x16;
const DW_FORM_sec_offset: u64 = 0x17;
const DW_FORM_exprloc: u64 = 0x18;
const DW_FORM_flag_present: u64 = 0x19;
const DW_FORM_strx: u64 = 0x1a;
const DW_FORM_addrx: u64 = 0x1b;
const DW_FORM_strx1: u64 = 0x25;
const DW_FORM_strx2: u64 = 0x26;
const DW_FORM_strx4: u64 = 0x27;
const DW_FORM_addrx1: u64 = 0x29;
const DW_FORM_addrx2: u64 = 0x2a;
const DW_FORM_addrx4: u64 = 0x2b;
const DW_FORM_data16: u64 = 0x1e;
const DW_FORM_line_strp: u64 = 0x1f;
const DW_FORM_implicit_const: u64 = 0x21;
const DW_FORM_rnglistx: u64 = 0x23;
const DW_FORM_loclistx: u64 = 0x22;
const DW_FORM_ref_sig8: u64 = 0x20;

// Children flag
const DW_CHILDREN_yes: u8 = 1;

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const AddressRange = struct {
    name: []const u8,
    low_pc: u64,
    high_pc: u64,
};

pub const LineEntry = struct {
    address: u64,
    file_index: u32,
    line: u32,
    column: u32,
    is_stmt: bool,
    end_sequence: bool,
};

pub const AbbrevEntry = struct {
    code: u64,
    tag: u64,
    has_children: bool,
    attributes: []const AbbrevAttr,
};

pub const AbbrevAttr = struct {
    name: u64,
    form: u64,
    implicit_const: i64,
};

pub const InlinedSubroutineInfo = struct {
    abstract_origin: u64 = 0, // DIE offset of the abstract function
    call_file: u32 = 0, // File index where the call site is
    call_line: u32 = 0, // Line number of the call site
    call_column: u32 = 0, // Column of the call site
    low_pc: u64 = 0, // Start of inlined code range
    high_pc: u64 = 0, // End of inlined code range
    name: ?[]const u8 = null, // Resolved name (from abstract_origin)
};

pub const FunctionInfo = struct {
    name: []const u8,
    low_pc: u64,
    high_pc: u64,
    inlined_subs: []const InlinedSubroutineInfo = &.{},
};

pub const VariableScope = enum {
    local,
    argument,
};

pub const TypeKind = enum {
    base,
    pointer,
    structure,
    array,
    enumeration,
    typedef_type,
    const_type,
    tagged_union,
    unknown,
};

pub const StructField = struct {
    name: []const u8,
    offset: u16,
    encoding: u8,
    byte_size: u8,
    type_name: []const u8,
};

pub const EnumValue = struct {
    name: []const u8,
    value: i64,
};

pub const VariantOption = struct {
    discr_value: i64,
    name: []const u8 = "",
    fields: []const StructField = &.{},
};

pub const TypeDescription = struct {
    kind: TypeKind = .base,
    name: []const u8 = "",
    encoding: u8 = 0,
    byte_size: u8 = 0,
    // Pointer target type name
    pointee_name: []const u8 = "",
    // Struct fields
    fields: []const StructField = &.{},
    // Array element info
    array_element_encoding: u8 = 0,
    array_element_size: u8 = 0,
    array_element_type_name: []const u8 = "",
    array_count: u32 = 0,
    // Enum values
    enum_values: []const EnumValue = &.{},
    // Variant parts (tagged unions)
    variants: []const VariantOption = &.{},
    discriminant_name: []const u8 = "",
};

pub const VariableInfo = struct {
    name: []const u8,
    location_expr: []const u8,
    type_encoding: u8,
    type_byte_size: u8,
    type_name: []const u8,
    scope: VariableScope = .local,
    type_desc: ?TypeDescription = null,
};

// ── LEB128 Encoding ────────────────────────────────────────────────────

pub fn readULEB128(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u32 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        if (shift < 64) {
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
        }
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift > 70) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

pub fn readSLEB128(data: []const u8, pos: *usize) !i64 {
    var result: u64 = 0;
    var shift: u32 = 0;
    var last_byte: u8 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        last_byte = byte;
        if (shift < 64) {
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
        }
        shift += 7;
        if (byte & 0x80 == 0) {
            // Sign extend if the sign bit of the last byte is set
            if (shift < 64 and (last_byte & 0x40) != 0) {
                result |= ~@as(u64, 0) << @intCast(shift);
            }
            return @bitCast(result);
        }
        if (shift > 70) return error.Overflow;
    }
    return error.UnexpectedEndOfData;
}

// ── Abbreviation Table Parser ──────────────────────────────────────────

pub fn parseAbbrevTable(data: []const u8, allocator: std.mem.Allocator) ![]AbbrevEntry {
    var entries: std.ArrayListUnmanaged(AbbrevEntry) = .empty;
    defer {
        // Only free attribute slices on error; on success, caller owns them
    }
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.attributes);
        }
        entries.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < data.len) {
        const code = try readULEB128(data, &pos);
        if (code == 0) break; // End of table

        const tag = try readULEB128(data, &pos);
        if (pos >= data.len) break;
        const has_children = data[pos] == DW_CHILDREN_yes;
        pos += 1;

        var attrs: std.ArrayListUnmanaged(AbbrevAttr) = .empty;
        errdefer attrs.deinit(allocator);

        while (pos < data.len) {
            const attr_name = try readULEB128(data, &pos);
            const attr_form = try readULEB128(data, &pos);
            if (attr_name == 0 and attr_form == 0) break;

            var implicit_const: i64 = 0;
            if (attr_form == DW_FORM_implicit_const) {
                implicit_const = try readSLEB128(data, &pos);
            }

            try attrs.append(allocator, .{
                .name = attr_name,
                .form = attr_form,
                .implicit_const = implicit_const,
            });
        }

        try entries.append(allocator, .{
            .code = code,
            .tag = tag,
            .has_children = has_children,
            .attributes = try attrs.toOwnedSlice(allocator),
        });
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn freeAbbrevTable(entries: []AbbrevEntry, allocator: std.mem.Allocator) void {
    for (entries) |entry| {
        allocator.free(entry.attributes);
    }
    allocator.free(entries);
}

// ── Line Program Parser ────────────────────────────────────────────────

pub const LineProgramHeader = struct {
    unit_length: u64,
    version: u16,
    header_length: u64,
    min_instruction_length: u8,
    max_ops_per_instruction: u8,
    default_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    standard_opcode_lengths: []const u8,
    directories: []const []const u8,
    files: []const FileEntry,
    header_end: usize, // offset where line program bytecode starts
    unit_end: usize, // offset where this unit ends
};

pub const FileEntry = struct {
    name: []const u8,
    dir_index: u64,
};

/// Result of parsing a DWARF line program, returning both line entries and file entries.
pub const LineProgramResult = struct {
    line_entries: []LineEntry,
    file_entries: []FileEntry,
};

/// Parse a DWARF line program and return both line entries and file entries.
pub fn parseLineProgramWithFiles(data: []const u8, allocator: std.mem.Allocator) !LineProgramResult {
    if (data.len < 4) return error.TooSmall;
    return parseLineProgramImpl(data, allocator, true, null);
}

/// Parse a DWARF line program with .debug_line_str resolution.
pub fn parseLineProgramWithFilesEx(data: []const u8, allocator: std.mem.Allocator, debug_line_str: ?[]const u8) !LineProgramResult {
    if (data.len < 4) return error.TooSmall;
    return parseLineProgramImpl(data, allocator, true, debug_line_str);
}

pub fn parseLineProgram(data: []const u8, allocator: std.mem.Allocator) ![]LineEntry {
    if (data.len < 4) return error.TooSmall;
    const result = try parseLineProgramImpl(data, allocator, false, null);
    return result.line_entries;
}

fn parseLineProgramImpl(data: []const u8, allocator: std.mem.Allocator, keep_files: bool, debug_line_str: ?[]const u8) !LineProgramResult {

    var pos: usize = 0;

    // Unit length
    const unit_length_32 = readU32(data, &pos) catch return error.TooSmall;
    var is_64bit = false;
    var unit_length: u64 = unit_length_32;
    if (unit_length_32 == 0xFFFFFFFF) {
        unit_length = readU64(data, &pos) catch return error.TooSmall;
        is_64bit = true;
    }
    const unit_end = pos + @as(usize, @intCast(unit_length));

    // Version
    const version = readU16(data, &pos) catch return error.TooSmall;

    // Address size and segment selector size (DWARF 5+)
    if (version >= 5) {
        if (pos >= data.len) return error.TooSmall;
        // address_size
        pos += 1;
        // segment_selector_size
        pos += 1;
    }

    // Header length
    var header_length: u64 = undefined;
    if (is_64bit) {
        header_length = readU64(data, &pos) catch return error.TooSmall;
    } else {
        header_length = readU32(data, &pos) catch return error.TooSmall;
    }
    const header_end = pos + @as(usize, @intCast(header_length));

    if (pos >= data.len) return error.TooSmall;
    const min_instruction_length = data[pos];
    pos += 1;

    if (version >= 4) {
        if (pos >= data.len) return error.TooSmall;
        // max_operations_per_instruction (not used in state machine yet)
        pos += 1;
    }

    if (pos >= data.len) return error.TooSmall;
    const default_is_stmt = data[pos] != 0;
    pos += 1;

    if (pos >= data.len) return error.TooSmall;
    const line_base: i8 = @bitCast(data[pos]);
    pos += 1;

    if (pos >= data.len) return error.TooSmall;
    const line_range = data[pos];
    pos += 1;

    if (pos >= data.len) return error.TooSmall;
    const opcode_base = data[pos];
    pos += 1;

    // Standard opcode lengths (opcode_base - 1 entries)
    if (opcode_base > 1) {
        const count = @as(usize, opcode_base) - 1;
        if (pos + count > data.len) return error.TooSmall;
        pos += count; // Skip standard opcode lengths
    }

    // Directories and files (DWARF 5 uses a different format)
    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer dirs.deinit(allocator);
    var files: std.ArrayListUnmanaged(FileEntry) = .empty;
    defer files.deinit(allocator);

    if (version >= 5) {
        // DWARF 5 directory/file entry format
        // directory_entry_format_count
        if (pos >= data.len) return error.TooSmall;
        const dir_format_count = data[pos];
        pos += 1;

        // Read directory entry format pairs
        var dir_forms: std.ArrayListUnmanaged([2]u64) = .empty;
        defer dir_forms.deinit(allocator);
        for (0..dir_format_count) |_| {
            const content_type = try readULEB128(data, &pos);
            const form = try readULEB128(data, &pos);
            try dir_forms.append(allocator, .{ content_type, form });
        }

        // directories_count
        const dir_count = try readULEB128(data, &pos);
        for (0..@intCast(dir_count)) |_| {
            var dir_name: []const u8 = "";
            for (dir_forms.items) |pair| {
                const form = pair[1];
                if (pair[0] == 1) { // DW_LNCT_path
                    if (form == DW_FORM_string) {
                        dir_name = readNullTermString(data, &pos);
                    } else if (form == DW_FORM_line_strp) {
                        const offset: u64 = if (is_64bit)
                            readU64(data, &pos) catch 0
                        else
                            readU32(data, &pos) catch 0;
                        if (debug_line_str) |lstr| {
                            dir_name = readStringAt(lstr, @intCast(offset)) orelse "";
                        }
                    } else if (form == DW_FORM_strp) {
                        if (is_64bit) {
                            pos += 8;
                        } else {
                            pos += 4;
                        }
                    } else {
                        try skipForm(data, &pos, form, is_64bit);
                    }
                } else {
                    try skipForm(data, &pos, form, is_64bit);
                }
            }
            try dirs.append(allocator, dir_name);
        }

        // file_name_entry_format_count
        if (pos >= data.len) return error.TooSmall;
        const file_format_count = data[pos];
        pos += 1;

        var file_forms: std.ArrayListUnmanaged([2]u64) = .empty;
        defer file_forms.deinit(allocator);
        for (0..file_format_count) |_| {
            const content_type = try readULEB128(data, &pos);
            const form = try readULEB128(data, &pos);
            try file_forms.append(allocator, .{ content_type, form });
        }

        // file_names_count
        const file_count = try readULEB128(data, &pos);
        for (0..@intCast(file_count)) |_| {
            var file_name: []const u8 = "";
            var dir_index: u64 = 0;
            for (file_forms.items) |pair| {
                const form = pair[1];
                if (pair[0] == 1) { // DW_LNCT_path
                    if (form == DW_FORM_string) {
                        file_name = readNullTermString(data, &pos);
                    } else if (form == DW_FORM_line_strp) {
                        const offset: u64 = if (is_64bit)
                            readU64(data, &pos) catch 0
                        else
                            readU32(data, &pos) catch 0;
                        if (debug_line_str) |lstr| {
                            file_name = readStringAt(lstr, @intCast(offset)) orelse "";
                        }
                    } else if (form == DW_FORM_strp) {
                        if (is_64bit) {
                            pos += 8;
                        } else {
                            pos += 4;
                        }
                    } else {
                        try skipForm(data, &pos, form, is_64bit);
                    }
                } else if (pair[0] == 2) { // DW_LNCT_directory_index
                    if (form == DW_FORM_data1 and pos < data.len) {
                        dir_index = data[pos];
                        pos += 1;
                    } else if (form == DW_FORM_data2) {
                        dir_index = readU16(data, &pos) catch 0;
                    } else if (form == DW_FORM_udata) {
                        dir_index = readULEB128(data, &pos) catch 0;
                    } else {
                        try skipForm(data, &pos, form, is_64bit);
                    }
                } else {
                    try skipForm(data, &pos, form, is_64bit);
                }
            }
            try files.append(allocator, .{ .name = file_name, .dir_index = dir_index });
        }
    } else {
        // DWARF 4 directory and file tables
        // Directories (null-terminated strings, terminated by empty string)
        while (pos < data.len and data[pos] != 0) {
            const dir = readNullTermString(data, &pos);
            try dirs.append(allocator, dir);
        }
        if (pos < data.len) pos += 1; // Skip terminating 0

        // Files
        while (pos < data.len and data[pos] != 0) {
            const name = readNullTermString(data, &pos);
            const dir_index = try readULEB128(data, &pos);
            _ = try readULEB128(data, &pos); // mod time
            _ = try readULEB128(data, &pos); // file size
            try files.append(allocator, .{ .name = name, .dir_index = dir_index });
        }
        if (pos < data.len) pos += 1; // Skip terminating 0
    }

    // Execute line program
    pos = header_end;
    var entries: std.ArrayListUnmanaged(LineEntry) = .empty;
    errdefer entries.deinit(allocator);

    // State machine
    var address: u64 = 0;
    var file_index: u32 = 1;
    var line: u32 = 1;
    var column: u32 = 0;
    var is_stmt: bool = default_is_stmt;
    var end_sequence: bool = false;

    while (pos < unit_end and pos < data.len) {
        const opcode = data[pos];
        pos += 1;

        if (opcode == 0) {
            // Extended opcode
            const ext_len = try readULEB128(data, &pos);
            const ext_end = pos + @as(usize, @intCast(ext_len));
            if (pos >= data.len) break;
            const ext_opcode = data[pos];
            pos += 1;

            switch (ext_opcode) {
                DW_LNE_end_sequence => {
                    end_sequence = true;
                    try entries.append(allocator, .{
                        .address = address,
                        .file_index = file_index,
                        .line = line,
                        .column = column,
                        .is_stmt = is_stmt,
                        .end_sequence = true,
                    });
                    // Reset state
                    address = 0;
                    file_index = 1;
                    line = 1;
                    column = 0;
                    is_stmt = default_is_stmt;
                    end_sequence = false;
                },
                DW_LNE_set_address => {
                    if (pos + 8 <= data.len) {
                        address = std.mem.readInt(u64, data[pos..][0..8], .little);
                    }
                    pos = ext_end;
                },
                DW_LNE_set_discriminator => {
                    _ = readULEB128(data, &pos) catch {};
                },
                else => {
                    pos = ext_end;
                },
            }
            if (pos < ext_end) pos = ext_end;
        } else if (opcode < opcode_base) {
            // Standard opcode
            switch (opcode) {
                DW_LNS_copy => {
                    try entries.append(allocator, .{
                        .address = address,
                        .file_index = file_index,
                        .line = line,
                        .column = column,
                        .is_stmt = is_stmt,
                        .end_sequence = false,
                    });
                },
                DW_LNS_advance_pc => {
                    const advance = try readULEB128(data, &pos);
                    address += advance * min_instruction_length;
                },
                DW_LNS_advance_line => {
                    const advance = try readSLEB128(data, &pos);
                    const new_line = @as(i64, line) + advance;
                    if (new_line > 0) {
                        line = @intCast(new_line);
                    }
                },
                DW_LNS_set_file => {
                    file_index = @intCast(try readULEB128(data, &pos));
                },
                DW_LNS_set_column => {
                    column = @intCast(try readULEB128(data, &pos));
                },
                DW_LNS_negate_stmt => {
                    is_stmt = !is_stmt;
                },
                DW_LNS_set_basic_block => {},
                DW_LNS_const_add_pc => {
                    if (line_range > 0) {
                        const adjust = (255 - opcode_base) / line_range;
                        address += @as(u64, adjust) * min_instruction_length;
                    }
                },
                DW_LNS_fixed_advance_pc => {
                    if (pos + 2 <= data.len) {
                        address += std.mem.readInt(u16, data[pos..][0..2], .little);
                        pos += 2;
                    }
                },
                DW_LNS_set_prologue_end, DW_LNS_set_epilogue_begin => {},
                DW_LNS_set_isa => {
                    _ = try readULEB128(data, &pos);
                },
                else => {
                    // Unknown standard opcode: skip its operands
                },
            }
        } else {
            // Special opcode
            if (line_range > 0) {
                const adjusted = @as(u32, opcode) - @as(u32, opcode_base);
                const line_inc = @as(i32, line_base) + @as(i32, @intCast(adjusted % line_range));
                const addr_inc = (adjusted / line_range) * min_instruction_length;
                address += addr_inc;
                const new_line = @as(i64, line) + line_inc;
                if (new_line > 0) {
                    line = @intCast(new_line);
                }
                try entries.append(allocator, .{
                    .address = address,
                    .file_index = file_index,
                    .line = line,
                    .column = column,
                    .is_stmt = is_stmt,
                    .end_sequence = false,
                });
            }
        }
    }

    const line_result = try entries.toOwnedSlice(allocator);

    if (keep_files) {
        const owned_files = try allocator.dupe(FileEntry, files.items);
        return .{
            .line_entries = line_result,
            .file_entries = owned_files,
        };
    }

    return .{
        .line_entries = line_result,
        .file_entries = &.{},
    };
}

/// Resolve an address to a source location using line entries.
pub fn resolveAddress(entries: []const LineEntry, files: []const FileEntry, address: u64) ?SourceLocation {
    // Find the line entry with the largest address <= target address
    var best: ?*const LineEntry = null;
    for (entries) |*entry| {
        if (entry.end_sequence) continue;
        if (entry.address <= address) {
            if (best == null or entry.address > best.?.address) {
                best = entry;
            }
        }
    }

    if (best) |entry| {
        const file_name = getFileName(files, entry.file_index);
        return .{
            .file = file_name,
            .line = entry.line,
            .column = entry.column,
        };
    }
    return null;
}

fn getFileName(files: []const FileEntry, index: u32) []const u8 {
    // DWARF 4: file indices are 1-based
    // DWARF 5: file indices are 0-based
    if (index > 0 and index - 1 < files.len) {
        return files[index - 1].name;
    }
    if (index < files.len) {
        return files[index].name;
    }
    return "<unknown>";
}

/// Additional sections needed for DWARF 5 indirect resolution.
pub const ExtraSections = struct {
    debug_str_offsets: ?[]const u8 = null,
    debug_addr: ?[]const u8 = null,
    debug_ranges: ?[]const u8 = null,
    debug_rnglists: ?[]const u8 = null,
    debug_loc: ?[]const u8 = null,
    debug_loclists: ?[]const u8 = null,
};

/// Parse .debug_info to extract function names.
pub fn parseCompilationUnit(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]FunctionInfo {
    return parseCompilationUnitEx(debug_info, debug_abbrev, debug_str, .{}, allocator);
}

/// Parse .debug_info with optional DWARF 5 sections.
/// Iterates over all compilation units to extract functions from the entire binary.
pub fn parseCompilationUnitEx(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    allocator: std.mem.Allocator,
) ![]FunctionInfo {
    var functions: std.ArrayListUnmanaged(FunctionInfo) = .empty;
    errdefer functions.deinit(allocator);

    if (debug_info.len < 11) return try functions.toOwnedSlice(allocator);

    var cu_pos: usize = 0;

    // Iterate over all compilation units
    while (cu_pos < debug_info.len) {
        var pos = cu_pos;

        // Compilation unit header
        const unit_length_32 = readU32(debug_info, &pos) catch break;
        var is_64bit = false;
        var unit_length: u64 = unit_length_32;
        if (unit_length_32 == 0xFFFFFFFF) {
            unit_length = readU64(debug_info, &pos) catch break;
            is_64bit = true;
        }
        if (unit_length == 0) break;
        const unit_end = pos + @as(usize, @intCast(unit_length));

        // Advance cu_pos to the next CU for the next iteration
        cu_pos = unit_end;

        const version = readU16(debug_info, &pos) catch continue;

        // DWARF 5 has unit_type before debug_abbrev_offset
        var address_size: u8 = 8;
        var abbrev_offset: u64 = undefined;
        if (version >= 5) {
            if (pos >= debug_info.len) continue;
            _ = debug_info[pos]; // unit_type
            pos += 1;
            if (pos >= debug_info.len) continue;
            address_size = debug_info[pos];
            pos += 1;
            if (is_64bit) {
                abbrev_offset = readU64(debug_info, &pos) catch continue;
            } else {
                abbrev_offset = readU32(debug_info, &pos) catch continue;
            }
        } else {
            if (is_64bit) {
                abbrev_offset = readU64(debug_info, &pos) catch continue;
            } else {
                abbrev_offset = readU32(debug_info, &pos) catch continue;
            }
            if (pos >= debug_info.len) continue;
            address_size = debug_info[pos];
            pos += 1;
        }

        // Parse abbreviation table at the given offset
        const abbrev_data = if (abbrev_offset < debug_abbrev.len)
            debug_abbrev[@intCast(abbrev_offset)..]
        else
            continue;

        const abbrevs = parseAbbrevTable(abbrev_data, allocator) catch continue;
        defer freeAbbrevTable(abbrevs, allocator);

        // Track DWARF 5 bases (set from DW_AT_str_offsets_base and DW_AT_addr_base)
        var str_offsets_base: u64 = 0;
        var addr_base: u64 = 0;
        const DW_AT_str_offsets_base_c: u64 = 0x72;
        const DW_AT_addr_base_c: u64 = 0x73;

        // First pass: find bases from compile unit DIE
        if (version >= 5) {
            var first_pos = pos;
            const first_code = readULEB128(debug_info, &first_pos) catch 0;
            if (first_code != 0) {
                if (findAbbrev(abbrevs, first_code)) |first_abbrev| {
                    for (first_abbrev.attributes) |attr| {
                        if (attr.form == DW_FORM_implicit_const) continue;

                        if (attr.name == DW_AT_str_offsets_base_c) {
                            if (attr.form == DW_FORM_sec_offset) {
                                str_offsets_base = if (is_64bit)
                                    readU64(debug_info, &first_pos) catch 0
                                else
                                    readU32(debug_info, &first_pos) catch 0;
                            } else {
                                skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                            }
                        } else if (attr.name == DW_AT_addr_base_c) {
                            if (attr.form == DW_FORM_sec_offset) {
                                addr_base = if (is_64bit)
                                    readU64(debug_info, &first_pos) catch 0
                                else
                                    readU32(debug_info, &first_pos) catch 0;
                            } else {
                                skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                            }
                        } else {
                            skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                        }
                    }
                }
            }
        }

        // Walk DIEs in this CU
        while (pos < unit_end and pos < debug_info.len) {
            const abbrev_code = readULEB128(debug_info, &pos) catch break;
            if (abbrev_code == 0) continue; // Null entry

            // Find abbreviation
            const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

            var name: ?[]const u8 = null;
            var linkage_name: ?[]const u8 = null;
            var low_pc: u64 = 0;
            var high_pc: u64 = 0;
            var high_pc_is_offset = false;

            for (abbrev.attributes) |attr| {
                if (attr.form == DW_FORM_implicit_const) {
                    continue;
                }

                // Read attribute value
                switch (attr.name) {
                    DW_AT_name => {
                        if (attr.form == DW_FORM_string) {
                            name = readNullTermString(debug_info, &pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                            if (debug_str) |str_section| {
                                name = readStringAt(str_section, @intCast(str_offset));
                            }
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            // DWARF 5: resolve through str_offsets table
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_linkage_name => {
                        if (attr.form == DW_FORM_string) {
                            linkage_name = readNullTermString(debug_info, &pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                            if (debug_str) |str_section| {
                                linkage_name = readStringAt(str_section, @intCast(str_offset));
                            }
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            linkage_name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_low_pc => {
                        if (attr.form == DW_FORM_addr) {
                            if (address_size == 8) {
                                low_pc = readU64(debug_info, &pos) catch break;
                            } else {
                                low_pc = readU32(debug_info, &pos) catch break;
                            }
                        } else if (attr.form == DW_FORM_addrx or attr.form == DW_FORM_addrx1 or
                            attr.form == DW_FORM_addrx2 or attr.form == DW_FORM_addrx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            low_pc = resolveAddrx(extra.debug_addr, addr_base, index, address_size);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_high_pc => {
                        if (attr.form == DW_FORM_addr) {
                            if (address_size == 8) {
                                high_pc = readU64(debug_info, &pos) catch break;
                            } else {
                                high_pc = readU32(debug_info, &pos) catch break;
                            }
                        } else if (attr.form == DW_FORM_data1 or attr.form == DW_FORM_data2 or
                            attr.form == DW_FORM_data4 or attr.form == DW_FORM_data8 or
                            attr.form == DW_FORM_udata or attr.form == DW_FORM_sdata)
                        {
                            high_pc_is_offset = true;
                            if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                                high_pc = debug_info[pos];
                                pos += 1;
                            } else if (attr.form == DW_FORM_data2) {
                                high_pc = readU16(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_data4) {
                                high_pc = readU32(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_data8) {
                                high_pc = readU64(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_udata) {
                                high_pc = readULEB128(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_sdata) {
                                const s = readSLEB128(debug_info, &pos) catch break;
                                high_pc = @intCast(s);
                            }
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    else => {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    },
                }
            }

            if (high_pc_is_offset) {
                high_pc = low_pc + high_pc;
            }

            if (abbrev.tag == DW_TAG_subprogram) {
                const func_name = name orelse linkage_name;
                if (func_name) |n| {
                    try functions.append(allocator, .{
                        .name = n,
                        .low_pc = low_pc,
                        .high_pc = high_pc,
                    });
                }
            }
        }
    }

    return try functions.toOwnedSlice(allocator);
}

/// Parse .debug_info to extract inlined subroutine information.
/// Returns a flat list of all DW_TAG_inlined_subroutine DIEs with resolved names.
pub fn parseInlinedSubroutines(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    allocator: std.mem.Allocator,
) ![]InlinedSubroutineInfo {
    var inlined_subs: std.ArrayListUnmanaged(InlinedSubroutineInfo) = .empty;
    errdefer inlined_subs.deinit(allocator);

    if (debug_info.len < 11) return try inlined_subs.toOwnedSlice(allocator);

    var cu_pos: usize = 0;

    while (cu_pos < debug_info.len) {
        var pos = cu_pos;

        const unit_length_32 = readU32(debug_info, &pos) catch break;
        var is_64bit = false;
        var unit_length: u64 = unit_length_32;
        if (unit_length_32 == 0xFFFFFFFF) {
            unit_length = readU64(debug_info, &pos) catch break;
            is_64bit = true;
        }
        if (unit_length == 0) break;
        const unit_end = pos + @as(usize, @intCast(unit_length));
        cu_pos = unit_end;

        const version = readU16(debug_info, &pos) catch continue;

        var address_size: u8 = 8;
        var abbrev_offset: u64 = undefined;
        if (version >= 5) {
            if (pos >= debug_info.len) continue;
            _ = debug_info[pos]; // unit_type
            pos += 1;
            if (pos >= debug_info.len) continue;
            address_size = debug_info[pos];
            pos += 1;
            if (is_64bit) {
                abbrev_offset = readU64(debug_info, &pos) catch continue;
            } else {
                abbrev_offset = readU32(debug_info, &pos) catch continue;
            }
        } else {
            if (is_64bit) {
                abbrev_offset = readU64(debug_info, &pos) catch continue;
            } else {
                abbrev_offset = readU32(debug_info, &pos) catch continue;
            }
            if (pos >= debug_info.len) continue;
            address_size = debug_info[pos];
            pos += 1;
        }

        const abbrev_data = if (abbrev_offset < debug_abbrev.len)
            debug_abbrev[@intCast(abbrev_offset)..]
        else
            continue;

        const abbrevs = parseAbbrevTable(abbrev_data, allocator) catch continue;
        defer freeAbbrevTable(abbrevs, allocator);

        // Track DWARF 5 bases
        var str_offsets_base: u64 = 0;
        var addr_base: u64 = 0;
        const DW_AT_str_offsets_base_c: u64 = 0x72;
        const DW_AT_addr_base_c: u64 = 0x73;

        if (version >= 5) {
            var first_pos = pos;
            const first_code = readULEB128(debug_info, &first_pos) catch 0;
            if (first_code != 0) {
                if (findAbbrev(abbrevs, first_code)) |first_abbrev| {
                    for (first_abbrev.attributes) |attr| {
                        if (attr.form == DW_FORM_implicit_const) continue;
                        if (attr.name == DW_AT_str_offsets_base_c) {
                            if (attr.form == DW_FORM_sec_offset) {
                                str_offsets_base = if (is_64bit)
                                    readU64(debug_info, &first_pos) catch 0
                                else
                                    readU32(debug_info, &first_pos) catch 0;
                            } else {
                                skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                            }
                        } else if (attr.name == DW_AT_addr_base_c) {
                            if (attr.form == DW_FORM_sec_offset) {
                                addr_base = if (is_64bit)
                                    readU64(debug_info, &first_pos) catch 0
                                else
                                    readU32(debug_info, &first_pos) catch 0;
                            } else {
                                skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                            }
                        } else {
                            skipForm(debug_info, &first_pos, attr.form, is_64bit) catch break;
                        }
                    }
                }
            }
        }

        // Map from DIE offset to function name for resolving abstract_origin
        var die_name_map = std.AutoHashMap(u64, []const u8).init(allocator);
        defer die_name_map.deinit();

        // Collect inlined subroutines for this CU
        var cu_inlined: std.ArrayListUnmanaged(InlinedSubroutineInfo) = .empty;
        defer cu_inlined.deinit(allocator);

        // Walk DIEs in this CU
        while (pos < unit_end and pos < debug_info.len) {
            const die_offset = pos;
            const abbrev_code = readULEB128(debug_info, &pos) catch break;
            if (abbrev_code == 0) continue;

            const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

            var name: ?[]const u8 = null;
            var linkage_name: ?[]const u8 = null;
            var low_pc: u64 = 0;
            var high_pc: u64 = 0;
            var high_pc_is_offset = false;
            var abstract_origin: u64 = 0;
            var call_file: u32 = 0;
            var call_line: u32 = 0;
            var call_column: u32 = 0;

            for (abbrev.attributes) |attr| {
                if (attr.form == DW_FORM_implicit_const) {
                    if (attr.name == DW_AT_call_file) {
                        call_file = @intCast(@as(u64, @bitCast(attr.implicit_const)));
                    } else if (attr.name == DW_AT_call_line) {
                        call_line = @intCast(@as(u64, @bitCast(attr.implicit_const)));
                    } else if (attr.name == DW_AT_call_column) {
                        call_column = @intCast(@as(u64, @bitCast(attr.implicit_const)));
                    }
                    continue;
                }

                switch (attr.name) {
                    DW_AT_name => {
                        if (attr.form == DW_FORM_string) {
                            name = readNullTermString(debug_info, &pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                            if (debug_str) |str_section| {
                                name = readStringAt(str_section, @intCast(str_offset));
                            }
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_linkage_name => {
                        if (attr.form == DW_FORM_string) {
                            linkage_name = readNullTermString(debug_info, &pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                            if (debug_str) |str_section| {
                                linkage_name = readStringAt(str_section, @intCast(str_offset));
                            }
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            linkage_name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_low_pc => {
                        if (attr.form == DW_FORM_addr) {
                            if (address_size == 8) {
                                low_pc = readU64(debug_info, &pos) catch break;
                            } else {
                                low_pc = readU32(debug_info, &pos) catch break;
                            }
                        } else if (attr.form == DW_FORM_addrx or attr.form == DW_FORM_addrx1 or
                            attr.form == DW_FORM_addrx2 or attr.form == DW_FORM_addrx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            low_pc = resolveAddrx(extra.debug_addr, addr_base, index, address_size);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_high_pc => {
                        if (attr.form == DW_FORM_addr) {
                            if (address_size == 8) {
                                high_pc = readU64(debug_info, &pos) catch break;
                            } else {
                                high_pc = readU32(debug_info, &pos) catch break;
                            }
                        } else if (attr.form == DW_FORM_data1 or attr.form == DW_FORM_data2 or
                            attr.form == DW_FORM_data4 or attr.form == DW_FORM_data8 or
                            attr.form == DW_FORM_udata or attr.form == DW_FORM_sdata)
                        {
                            high_pc_is_offset = true;
                            if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                                high_pc = debug_info[pos];
                                pos += 1;
                            } else if (attr.form == DW_FORM_data2) {
                                high_pc = readU16(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_data4) {
                                high_pc = readU32(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_data8) {
                                high_pc = readU64(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_udata) {
                                high_pc = readULEB128(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_sdata) {
                                const s = readSLEB128(debug_info, &pos) catch break;
                                high_pc = @intCast(s);
                            }
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_abstract_origin => {
                        if (attr.form == DW_FORM_ref4) {
                            abstract_origin = readU32(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref1 and pos < debug_info.len) {
                            abstract_origin = debug_info[pos];
                            pos += 1;
                        } else if (attr.form == DW_FORM_ref2) {
                            abstract_origin = readU16(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref8) {
                            abstract_origin = readU64(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref_udata) {
                            abstract_origin = readULEB128(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref_addr) {
                            if (is_64bit) {
                                abstract_origin = readU64(debug_info, &pos) catch break;
                            } else {
                                abstract_origin = readU32(debug_info, &pos) catch break;
                            }
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_call_file => {
                        if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                            call_file = debug_info[pos];
                            pos += 1;
                        } else if (attr.form == DW_FORM_data2) {
                            call_file = @intCast(readU16(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_data4) {
                            call_file = @intCast(readU32(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_udata) {
                            call_file = @intCast(readULEB128(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_sdata) {
                            const s = readSLEB128(debug_info, &pos) catch break;
                            call_file = @intCast(@as(u64, @bitCast(s)));
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_call_line => {
                        if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                            call_line = debug_info[pos];
                            pos += 1;
                        } else if (attr.form == DW_FORM_data2) {
                            call_line = @intCast(readU16(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_data4) {
                            call_line = @intCast(readU32(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_udata) {
                            call_line = @intCast(readULEB128(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_sdata) {
                            const s = readSLEB128(debug_info, &pos) catch break;
                            call_line = @intCast(@as(u64, @bitCast(s)));
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_call_column => {
                        if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                            call_column = debug_info[pos];
                            pos += 1;
                        } else if (attr.form == DW_FORM_data2) {
                            call_column = @intCast(readU16(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_data4) {
                            call_column = @intCast(readU32(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_udata) {
                            call_column = @intCast(readULEB128(debug_info, &pos) catch break);
                        } else if (attr.form == DW_FORM_sdata) {
                            const s = readSLEB128(debug_info, &pos) catch break;
                            call_column = @intCast(@as(u64, @bitCast(s)));
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    else => {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    },
                }
            }

            if (high_pc_is_offset) {
                high_pc = low_pc + high_pc;
            }

            // Record subprogram names for abstract_origin resolution
            if (abbrev.tag == DW_TAG_subprogram) {
                const func_name = name orelse linkage_name;
                if (func_name) |n| {
                    die_name_map.put(die_offset, n) catch {};
                }
            }

            // Collect inlined subroutines
            if (abbrev.tag == DW_TAG_inlined_subroutine) {
                if (low_pc > 0 or high_pc > 0) {
                    try cu_inlined.append(allocator, .{
                        .abstract_origin = abstract_origin,
                        .call_file = call_file,
                        .call_line = call_line,
                        .call_column = call_column,
                        .low_pc = low_pc,
                        .high_pc = high_pc,
                        .name = name,
                    });
                }
            }
        }

        // Resolve names for inlined subroutines via abstract_origin
        for (cu_inlined.items) |*isub| {
            if (isub.name == null and isub.abstract_origin != 0) {
                isub.name = die_name_map.get(isub.abstract_origin);
            }
        }

        try inlined_subs.appendSlice(allocator, cu_inlined.items);
    }

    return try inlined_subs.toOwnedSlice(allocator);
}

/// Find all inlined subroutines whose PC range contains the given address.
pub fn findInlinedSubroutines(
    inlined_subs: []const InlinedSubroutineInfo,
    address: u64,
    allocator: std.mem.Allocator,
) ![]const InlinedSubroutineInfo {
    var matches: std.ArrayListUnmanaged(InlinedSubroutineInfo) = .empty;
    errdefer matches.deinit(allocator);

    for (inlined_subs) |isub| {
        if (isub.low_pc > 0 and isub.high_pc > 0 and
            address >= isub.low_pc and address < isub.high_pc)
        {
            try matches.append(allocator, isub);
        }
    }

    return try matches.toOwnedSlice(allocator);
}

/// Read an index value from a DW_FORM_strx* or DW_FORM_addrx* form.
fn readFormIndex(data: []const u8, pos: *usize, form: u64) !u64 {
    return switch (form) {
        DW_FORM_strx1, DW_FORM_addrx1 => blk: {
            if (pos.* >= data.len) break :blk error.OutOfBounds;
            const v = data[pos.*];
            pos.* += 1;
            break :blk @as(u64, v);
        },
        DW_FORM_strx2, DW_FORM_addrx2 => readU16(data, pos) catch |e| return e,
        DW_FORM_strx4, DW_FORM_addrx4 => readU32(data, pos) catch |e| return e,
        DW_FORM_strx, DW_FORM_addrx => readULEB128(data, pos),
        else => error.UnknownForm,
    };
}

/// Resolve a DW_FORM_strx index to a string via .debug_str_offsets and .debug_str.
fn resolveStrx(debug_str: ?[]const u8, str_offsets: ?[]const u8, base: u64, index: u64, is_64bit: bool) ?[]const u8 {
    const offsets = str_offsets orelse return null;
    const str = debug_str orelse return null;

    const entry_size: u64 = if (is_64bit) 8 else 4;
    const offset_pos = base + index * entry_size;

    if (offset_pos + entry_size > offsets.len) return null;

    const str_offset: u64 = if (is_64bit)
        std.mem.readInt(u64, offsets[@intCast(offset_pos)..][0..8], .little)
    else
        std.mem.readInt(u32, offsets[@intCast(offset_pos)..][0..4], .little);

    return readStringAt(str, @intCast(str_offset));
}

/// Resolve a DW_FORM_addrx index to an address via .debug_addr.
fn resolveAddrx(debug_addr_section: ?[]const u8, base: u64, index: u64, address_size: u8) u64 {
    const addr_data = debug_addr_section orelse return 0;

    const offset_pos = base + index * address_size;
    if (offset_pos + address_size > addr_data.len) return 0;

    if (address_size == 8) {
        return std.mem.readInt(u64, addr_data[@intCast(offset_pos)..][0..8], .little);
    } else if (address_size == 4) {
        return std.mem.readInt(u32, addr_data[@intCast(offset_pos)..][0..4], .little);
    }
    return 0;
}

/// Find a function by name in parsed function list.
pub fn resolveFunction(functions: []const FunctionInfo, name: []const u8) ?AddressRange {
    for (functions) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return .{
                .name = f.name,
                .low_pc = f.low_pc,
                .high_pc = f.high_pc,
            };
        }
    }
    return null;
}

// ── Range List Parsing ─────────────────────────────────────────────────

// DWARF 5 range list entry kinds
const DW_RLE_end_of_list: u8 = 0x00;
const DW_RLE_base_addressx: u8 = 0x01;
const DW_RLE_startx_endx: u8 = 0x02;
const DW_RLE_startx_length: u8 = 0x03;
const DW_RLE_offset_pair: u8 = 0x04;
const DW_RLE_base_address: u8 = 0x06;
const DW_RLE_start_end: u8 = 0x07;
const DW_RLE_start_length: u8 = 0x08;

pub const AddressRangeEntry = struct {
    begin: u64,
    end: u64,
};

/// Unified helper: check if a PC falls within a DIE's ranges, dispatching to the correct
/// range list evaluator based on DWARF version and available sections.
fn pcInRanges(
    extra: ExtraSections,
    dwarf_version: u16,
    ranges_offset: u64,
    is_rnglistx: bool,
    rnglists_base: u64,
    pc: u64,
    base_address: u64,
) bool {
    return pcInRangesEx(extra, dwarf_version, ranges_offset, is_rnglistx, rnglists_base, pc, base_address, 0, 8);
}

/// Unified helper with .debug_addr resolution support for indexed range list entries.
fn pcInRangesEx(
    extra: ExtraSections,
    dwarf_version: u16,
    ranges_offset: u64,
    is_rnglistx: bool,
    rnglists_base: u64,
    pc: u64,
    base_address: u64,
    addr_base: u64,
    address_size: u8,
) bool {
    if (dwarf_version >= 5) {
        const rnglists_data = extra.debug_rnglists orelse return false;
        var actual_offset = ranges_offset;
        if (is_rnglistx) {
            // DW_FORM_rnglistx: ranges_offset is an index into the offset table
            // at rnglists_base. Each entry is a 4-byte offset from rnglists_base.
            const table_pos = rnglists_base + ranges_offset * 4;
            if (table_pos + 4 > rnglists_data.len) return false;
            actual_offset = rnglists_base + std.mem.readInt(u32, rnglists_data[@intCast(table_pos)..][0..4], .little);
        }
        return pcInRangeListDwarf5Full(rnglists_data, actual_offset, pc, base_address, extra.debug_addr, addr_base, address_size);
    } else {
        const ranges_data = extra.debug_ranges orelse return false;
        return pcInRangeList(ranges_data, ranges_offset, pc, base_address);
    }
}

/// Check if a PC falls within a DWARF 4 range list (.debug_ranges).
pub fn pcInRangeList(
    ranges_data: []const u8,
    ranges_offset: u64,
    pc: u64,
    base_address: u64,
) bool {
    if (ranges_offset >= ranges_data.len) return false;
    var pos: usize = @intCast(ranges_offset);
    var base = base_address;

    while (pos + 16 <= ranges_data.len) {
        const begin = std.mem.readInt(u64, ranges_data[pos..][0..8], .little);
        pos += 8;
        const end = std.mem.readInt(u64, ranges_data[pos..][0..8], .little);
        pos += 8;

        // End of list
        if (begin == 0 and end == 0) return false;

        // Base address selection entry
        if (begin == std.math.maxInt(u64)) {
            base = end;
            continue;
        }

        if (pc >= base + begin and pc < base + end) return true;
    }

    return false;
}

/// Check if a PC falls within a DWARF 5 range list (.debug_rnglists).
pub fn pcInRangeListDwarf5(
    rnglists_data: []const u8,
    rng_offset: u64,
    pc: u64,
    base_address: u64,
) bool {
    return pcInRangeListDwarf5Full(rnglists_data, rng_offset, pc, base_address, null, 0, 8);
}

/// Check if a PC falls within a DWARF 5 range list, with .debug_addr resolution
/// for DW_RLE_base_addressx, DW_RLE_startx_endx, and DW_RLE_startx_length.
pub fn pcInRangeListDwarf5Full(
    rnglists_data: []const u8,
    rng_offset: u64,
    pc: u64,
    base_address: u64,
    debug_addr_data: ?[]const u8,
    addr_base: u64,
    address_size: u8,
) bool {
    if (rng_offset >= rnglists_data.len) return false;
    var pos: usize = @intCast(rng_offset);
    var base = base_address;

    while (pos < rnglists_data.len) {
        const kind = rnglists_data[pos];
        pos += 1;

        switch (kind) {
            DW_RLE_end_of_list => return false,
            DW_RLE_base_address => {
                if (pos + 8 > rnglists_data.len) return false;
                base = std.mem.readInt(u64, rnglists_data[pos..][0..8], .little);
                pos += 8;
            },
            DW_RLE_offset_pair => {
                const begin = readULEB128(rnglists_data, &pos) catch return false;
                const end = readULEB128(rnglists_data, &pos) catch return false;
                if (pc >= base + begin and pc < base + end) return true;
            },
            DW_RLE_start_end => {
                if (pos + 16 > rnglists_data.len) return false;
                const begin = std.mem.readInt(u64, rnglists_data[pos..][0..8], .little);
                pos += 8;
                const end = std.mem.readInt(u64, rnglists_data[pos..][0..8], .little);
                pos += 8;
                if (pc >= begin and pc < end) return true;
            },
            DW_RLE_start_length => {
                if (pos + 8 > rnglists_data.len) return false;
                const begin = std.mem.readInt(u64, rnglists_data[pos..][0..8], .little);
                pos += 8;
                const length = readULEB128(rnglists_data, &pos) catch return false;
                if (pc >= begin and pc < begin + length) return true;
            },
            DW_RLE_base_addressx => {
                const index = readULEB128(rnglists_data, &pos) catch return false;
                base = resolveAddrx(debug_addr_data, addr_base, index, address_size);
            },
            DW_RLE_startx_endx => {
                const start_idx = readULEB128(rnglists_data, &pos) catch return false;
                const end_idx = readULEB128(rnglists_data, &pos) catch return false;
                const begin = resolveAddrx(debug_addr_data, addr_base, start_idx, address_size);
                const end = resolveAddrx(debug_addr_data, addr_base, end_idx, address_size);
                if (pc >= begin and pc < end) return true;
            },
            DW_RLE_startx_length => {
                const start_idx = readULEB128(rnglists_data, &pos) catch return false;
                const length = readULEB128(rnglists_data, &pos) catch return false;
                const begin = resolveAddrx(debug_addr_data, addr_base, start_idx, address_size);
                if (pc >= begin and pc < begin + length) return true;
            },
            else => return false,
        }
    }

    return false;
}

// ── .debug_aranges Parser ──────────────────────────────────────────────

pub const ArangeEntry = struct {
    start: u64,
    length: u64,
    cu_offset: u64,
};

/// Parse .debug_aranges to build a map from address ranges to CU offsets.
pub fn parseAranges(data: []const u8, allocator: std.mem.Allocator) ![]ArangeEntry {
    var entries: std.ArrayListUnmanaged(ArangeEntry) = .empty;
    errdefer entries.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        // Unit header
        if (pos + 4 > data.len) break;
        const unit_length_32 = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (unit_length_32 == 0) break;

        var is_64bit = false;
        var unit_length: u64 = unit_length_32;
        if (unit_length_32 == 0xFFFFFFFF) {
            if (pos + 8 > data.len) break;
            unit_length = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
            is_64bit = true;
        }

        const unit_end = pos + @as(usize, @intCast(unit_length));
        if (unit_end > data.len) break;

        // Version (2)
        if (pos + 2 > data.len) break;
        pos += 2; // version

        // CU offset
        var cu_offset: u64 = 0;
        if (is_64bit) {
            if (pos + 8 > data.len) break;
            cu_offset = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
        } else {
            if (pos + 4 > data.len) break;
            cu_offset = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
        }

        // Address size
        if (pos >= data.len) break;
        const addr_size = data[pos];
        pos += 1;

        // Segment selector size
        if (pos >= data.len) break;
        pos += 1; // segment_size

        // Align to 2 * addr_size boundary
        const tuple_size: usize = @as(usize, addr_size) * 2;
        if (tuple_size > 0) {
            const align_to = tuple_size;
            const remainder = pos % align_to;
            if (remainder != 0) {
                pos += align_to - remainder;
            }
        }

        // Read address/length pairs
        while (pos + tuple_size <= unit_end) {
            var start: u64 = 0;
            var length: u64 = 0;

            if (addr_size == 8) {
                start = std.mem.readInt(u64, data[pos..][0..8], .little);
                pos += 8;
                length = std.mem.readInt(u64, data[pos..][0..8], .little);
                pos += 8;
            } else if (addr_size == 4) {
                start = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;
                length = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;
            } else {
                break;
            }

            // End of list
            if (start == 0 and length == 0) break;

            try entries.append(allocator, .{
                .start = start,
                .length = length,
                .cu_offset = cu_offset,
            });
        }

        pos = unit_end;
    }

    const result = try entries.toOwnedSlice(allocator);

    // Sort by start address for binary search in findCuForPc
    std.mem.sort(ArangeEntry, result, {}, struct {
        fn lessThan(_: void, a: ArangeEntry, b: ArangeEntry) bool {
            return a.start < b.start;
        }
    }.lessThan);

    return result;
}

/// Find the CU offset for a given PC using parsed aranges.
/// Aranges are sorted by start address for O(log n) binary search.
pub fn findCuForPc(aranges: []const ArangeEntry, pc: u64) ?u64 {
    if (aranges.len == 0) return null;

    // Binary search: find the last entry where start <= pc
    var lo: usize = 0;
    var hi: usize = aranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (aranges[mid].start <= pc) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    // lo is now the index after the last entry with start <= pc
    if (lo == 0) return null;
    const entry = aranges[lo - 1];
    if (pc >= entry.start and pc < entry.start + entry.length) {
        return entry.cu_offset;
    }
    return null;
}

// ── Type Graph Infrastructure ──────────────────────────────────────────

/// Raw type DIE information collected in the first pass.
const TypeDie = struct {
    tag: u64,
    name: ?[]const u8 = null,
    encoding: u8 = 0,
    byte_size: u8 = 0,
    type_ref: u64 = 0, // DW_AT_type reference (CU-relative offset)
    type_sig8: u64 = 0, // DW_FORM_ref_sig8 type signature
    has_type_ref: bool = false,
    has_type_sig8: bool = false,
    // For struct members
    member_location: u16 = 0,
    // For array subrange
    array_count: u32 = 0,
    // For enumerator
    const_value: i64 = 0,
    // Parent die offset (for members/subranges/enumerators)
    parent_offset: u64 = 0,
    has_parent: bool = false,
    // Bit-level layout
    bit_offset: u8 = 0,
    bit_size: u8 = 0,
    // For DW_TAG_inheritance: base class offset
    data_member_location_inheritance: u16 = 0,
    // Containing type for ptr_to_member
    containing_type_ref: u64 = 0,
    has_containing_type: bool = false,
    // For DW_TAG_variant_part: discriminant member reference
    discr_ref: u64 = 0,
    has_discr_ref: bool = false,
    // For DW_TAG_variant: discriminant value
    discr_value: i64 = 0,
    has_discr_value: bool = false,
};

/// Collect all type DIEs from a compilation unit into a type map.
/// Returns a map from DIE offset to TypeDie.
fn collectTypeDies(
    debug_info: []const u8,
    abbrevs: []const AbbrevEntry,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    str_offsets_base: u64,
    is_64bit: bool,
    address_size: u8,
    start_pos: usize,
    unit_end: usize,
    allocator: std.mem.Allocator,
) !std.AutoHashMap(u64, TypeDie) {
    var type_map = std.AutoHashMap(u64, TypeDie).init(allocator);
    errdefer type_map.deinit();

    // Track parent DIE offset stack for children
    var parent_stack: [64]u64 = undefined;
    var parent_depth: usize = 0;

    var scan_pos = start_pos;
    while (scan_pos < unit_end and scan_pos < debug_info.len) {
        const die_offset = scan_pos;
        const abbrev_code = readULEB128(debug_info, &scan_pos) catch break;
        if (abbrev_code == 0) {
            // Null DIE - pop parent
            if (parent_depth > 0) parent_depth -= 1;
            continue;
        }
        const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

        var die = TypeDie{ .tag = abbrev.tag };

        // Track parent for children (members, subranges, enumerators)
        if (parent_depth > 0) {
            die.parent_offset = parent_stack[parent_depth - 1];
            die.has_parent = true;
        }

        for (abbrev.attributes) |attr| {
            if (attr.form == DW_FORM_implicit_const) {
                // Handle implicit_const for const_value and discr_value
                if (attr.name == DW_AT_const_value) {
                    die.const_value = attr.implicit_const;
                } else if (attr.name == DW_AT_discr_value) {
                    die.discr_value = attr.implicit_const;
                    die.has_discr_value = true;
                }
                continue;
            }
            switch (attr.name) {
                DW_AT_name => {
                    if (attr.form == DW_FORM_string) {
                        die.name = readNullTermString(debug_info, &scan_pos);
                    } else if (attr.form == DW_FORM_strp) {
                        const str_offset = if (is_64bit)
                            readU64(debug_info, &scan_pos) catch break
                        else
                            readU32(debug_info, &scan_pos) catch break;
                        if (debug_str) |s| die.name = readStringAt(s, @intCast(str_offset));
                    } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                        attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                    {
                        const index = readFormIndex(debug_info, &scan_pos, attr.form) catch break;
                        die.name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_encoding => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.encoding = debug_info[scan_pos];
                        scan_pos += 1;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_byte_size => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.byte_size = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_data2) {
                        const v = readU16(debug_info, &scan_pos) catch break;
                        die.byte_size = if (v <= 255) @intCast(v) else 0;
                    } else if (attr.form == DW_FORM_udata) {
                        const v = readULEB128(debug_info, &scan_pos) catch break;
                        die.byte_size = if (v <= 255) @intCast(v) else 0;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_type => {
                    if (attr.form == DW_FORM_ref_sig8) {
                        die.type_sig8 = readU64(debug_info, &scan_pos) catch break;
                        die.has_type_sig8 = true;
                    } else {
                        die.has_type_ref = true;
                        if (attr.form == DW_FORM_ref4) {
                            die.type_ref = readU32(debug_info, &scan_pos) catch break;
                        } else if (attr.form == DW_FORM_ref1 and scan_pos < debug_info.len) {
                            die.type_ref = debug_info[scan_pos];
                            scan_pos += 1;
                        } else if (attr.form == DW_FORM_ref2) {
                            die.type_ref = readU16(debug_info, &scan_pos) catch break;
                        } else if (attr.form == DW_FORM_ref8) {
                            die.type_ref = readU64(debug_info, &scan_pos) catch break;
                        } else if (attr.form == DW_FORM_ref_udata) {
                            die.type_ref = readULEB128(debug_info, &scan_pos) catch break;
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    }
                },
                DW_AT_data_member_location => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.member_location = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_data2) {
                        die.member_location = readU16(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_udata) {
                        const v = readULEB128(debug_info, &scan_pos) catch break;
                        die.member_location = if (v <= 0xFFFF) @intCast(v) else 0;
                    } else if (attr.form == DW_FORM_sdata) {
                        const v = readSLEB128(debug_info, &scan_pos) catch break;
                        die.member_location = if (v >= 0 and v <= 0xFFFF) @intCast(v) else 0;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_upper_bound => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.array_count = @as(u32, debug_info[scan_pos]) + 1;
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_data2) {
                        const v = readU16(debug_info, &scan_pos) catch break;
                        die.array_count = @as(u32, v) + 1;
                    } else if (attr.form == DW_FORM_data4) {
                        const v = readU32(debug_info, &scan_pos) catch break;
                        die.array_count = v + 1;
                    } else if (attr.form == DW_FORM_udata) {
                        const v = readULEB128(debug_info, &scan_pos) catch break;
                        die.array_count = @as(u32, @intCast(v)) + 1;
                    } else if (attr.form == DW_FORM_sdata) {
                        const v = readSLEB128(debug_info, &scan_pos) catch break;
                        if (v >= 0) die.array_count = @as(u32, @intCast(v)) + 1;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_count => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.array_count = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_udata) {
                        const v = readULEB128(debug_info, &scan_pos) catch break;
                        die.array_count = @intCast(v);
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_const_value => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.const_value = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_data2) {
                        die.const_value = readU16(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_data4) {
                        die.const_value = readU32(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_data8) {
                        die.const_value = @bitCast(readU64(debug_info, &scan_pos) catch break);
                    } else if (attr.form == DW_FORM_sdata) {
                        die.const_value = readSLEB128(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_udata) {
                        die.const_value = @intCast(readULEB128(debug_info, &scan_pos) catch break);
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_bit_offset => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.bit_offset = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_udata) {
                        const v = readULEB128(debug_info, &scan_pos) catch break;
                        die.bit_offset = if (v <= 255) @intCast(v) else 0;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_bit_size => {
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.bit_size = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_udata) {
                        const v = readULEB128(debug_info, &scan_pos) catch break;
                        die.bit_size = if (v <= 255) @intCast(v) else 0;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_discr => {
                    // Reference to the discriminant member
                    die.has_discr_ref = true;
                    if (attr.form == DW_FORM_ref4) {
                        die.discr_ref = readU32(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_ref1 and scan_pos < debug_info.len) {
                        die.discr_ref = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_ref2) {
                        die.discr_ref = readU16(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_ref8) {
                        die.discr_ref = readU64(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_ref_udata) {
                        die.discr_ref = readULEB128(debug_info, &scan_pos) catch break;
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_discr_value => {
                    die.has_discr_value = true;
                    if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                        die.discr_value = debug_info[scan_pos];
                        scan_pos += 1;
                    } else if (attr.form == DW_FORM_data2) {
                        die.discr_value = readU16(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_data4) {
                        die.discr_value = readU32(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_data8) {
                        die.discr_value = @bitCast(readU64(debug_info, &scan_pos) catch break);
                    } else if (attr.form == DW_FORM_sdata) {
                        die.discr_value = readSLEB128(debug_info, &scan_pos) catch break;
                    } else if (attr.form == DW_FORM_udata) {
                        die.discr_value = @intCast(readULEB128(debug_info, &scan_pos) catch break);
                    } else {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    }
                },
                else => {
                    skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                },
            }
        }

        // Store type-related DIEs
        const is_type_die = (abbrev.tag == DW_TAG_base_type or
            abbrev.tag == DW_TAG_structure_type or
            abbrev.tag == DW_TAG_array_type or
            abbrev.tag == DW_TAG_pointer_type or
            abbrev.tag == DW_TAG_typedef or
            abbrev.tag == DW_TAG_const_type or
            abbrev.tag == DW_TAG_volatile_type or
            abbrev.tag == DW_TAG_restrict_type or
            abbrev.tag == DW_TAG_enumeration_type or
            abbrev.tag == DW_TAG_member or
            abbrev.tag == DW_TAG_subrange_type or
            abbrev.tag == DW_TAG_enumerator or
            abbrev.tag == DW_TAG_unspecified_type or
            abbrev.tag == DW_TAG_class_type or
            abbrev.tag == DW_TAG_interface_type or
            abbrev.tag == DW_TAG_union_type or
            abbrev.tag == DW_TAG_reference_type or
            abbrev.tag == DW_TAG_rvalue_reference_type or
            abbrev.tag == DW_TAG_subroutine_type or
            abbrev.tag == DW_TAG_atomic_type or
            abbrev.tag == DW_TAG_ptr_to_member_type or
            abbrev.tag == DW_TAG_inheritance or
            abbrev.tag == DW_TAG_variant_part or
            abbrev.tag == DW_TAG_variant);

        if (is_type_die) {
            type_map.put(die_offset, die) catch {};
        }

        if (abbrev.has_children) {
            if (parent_depth < parent_stack.len) {
                parent_stack[parent_depth] = die_offset;
                parent_depth += 1;
            }
        }
    }

    _ = address_size;
    return type_map;
}

/// Resolve a type reference through the type graph to produce a TypeDescription.
/// Follows pointer chains, typedefs, const qualifiers, etc.
fn resolveTypeDescription(
    type_map: *const std.AutoHashMap(u64, TypeDie),
    type_ref: u64,
    allocator: std.mem.Allocator,
) !TypeDescription {
    return resolveTypeDescriptionImpl(type_map, type_ref, allocator, 0);
}

fn resolveTypeDescriptionImpl(
    type_map: *const std.AutoHashMap(u64, TypeDie),
    type_ref: u64,
    allocator: std.mem.Allocator,
    depth: u32,
) !TypeDescription {
    // Guard against infinite loops
    if (depth > 20) return TypeDescription{ .kind = .unknown, .name = "<recursive type>" };

    const die = type_map.get(type_ref) orelse return TypeDescription{ .kind = .unknown };

    switch (die.tag) {
        DW_TAG_base_type => {
            return TypeDescription{
                .kind = .base,
                .name = die.name orelse "",
                .encoding = die.encoding,
                .byte_size = die.byte_size,
            };
        },
        DW_TAG_pointer_type, DW_TAG_reference_type, DW_TAG_rvalue_reference_type, DW_TAG_ptr_to_member_type => {
            var desc = TypeDescription{
                .kind = .pointer,
                .name = die.name orelse "",
                .byte_size = if (die.byte_size > 0) die.byte_size else 8, // pointers are 8 bytes on 64-bit
            };
            if (die.has_type_ref) {
                const pointee = try resolveTypeDescriptionImpl(type_map, die.type_ref, allocator, depth + 1);
                desc.pointee_name = pointee.name;
            } else {
                desc.pointee_name = "void";
            }
            return desc;
        },
        DW_TAG_structure_type, DW_TAG_class_type, DW_TAG_interface_type, DW_TAG_union_type => {
            // Collect member fields
            var fields = std.ArrayListUnmanaged(StructField).empty;
            errdefer {
                allocator.free(fields.allocatedSlice());
            }

            var iter = type_map.iterator();
            while (iter.next()) |entry| {
                const member_die = entry.value_ptr;
                if (member_die.tag == DW_TAG_member and member_die.has_parent and member_die.parent_offset == type_ref) {
                    // Resolve member type
                    var mem_encoding: u8 = 0;
                    var mem_byte_size: u8 = 0;
                    var mem_type_name: []const u8 = "";
                    if (member_die.has_type_ref) {
                        if (type_map.get(member_die.type_ref)) |member_type| {
                            mem_encoding = member_type.encoding;
                            mem_byte_size = member_type.byte_size;
                            mem_type_name = member_type.name orelse "";
                        }
                    }

                    try fields.append(allocator, .{
                        .name = member_die.name orelse "",
                        .offset = member_die.member_location,
                        .encoding = mem_encoding,
                        .byte_size = mem_byte_size,
                        .type_name = mem_type_name,
                    });
                }
            }

            return TypeDescription{
                .kind = .structure,
                .name = die.name orelse "",
                .byte_size = die.byte_size,
                .fields = try fields.toOwnedSlice(allocator),
            };
        },
        DW_TAG_array_type => {
            var desc = TypeDescription{
                .kind = .array,
                .name = die.name orelse "",
                .byte_size = die.byte_size,
            };

            // Find element type
            if (die.has_type_ref) {
                if (type_map.get(die.type_ref)) |elem_type| {
                    desc.array_element_encoding = elem_type.encoding;
                    desc.array_element_size = elem_type.byte_size;
                    desc.array_element_type_name = elem_type.name orelse "";
                }
            }

            // Find subrange for count
            var iter = type_map.iterator();
            while (iter.next()) |entry| {
                const child = entry.value_ptr;
                if (child.tag == DW_TAG_subrange_type and child.has_parent and child.parent_offset == type_ref) {
                    desc.array_count = child.array_count;
                    break;
                }
            }

            return desc;
        },
        DW_TAG_enumeration_type => {
            // Collect enumerator values
            var enum_vals = std.ArrayListUnmanaged(EnumValue).empty;
            errdefer {
                allocator.free(enum_vals.allocatedSlice());
            }

            var iter = type_map.iterator();
            while (iter.next()) |entry| {
                const child = entry.value_ptr;
                if (child.tag == DW_TAG_enumerator and child.has_parent and child.parent_offset == type_ref) {
                    try enum_vals.append(allocator, .{
                        .name = child.name orelse "",
                        .value = child.const_value,
                    });
                }
            }

            return TypeDescription{
                .kind = .enumeration,
                .name = die.name orelse "",
                .byte_size = die.byte_size,
                .encoding = die.encoding,
                .enum_values = try enum_vals.toOwnedSlice(allocator),
            };
        },
        DW_TAG_variant_part => {
            // Tagged union (discriminated union) — collect DW_TAG_variant children
            var variants = std.ArrayListUnmanaged(VariantOption).empty;
            errdefer {
                for (variants.items) |v| {
                    if (v.fields.len > 0) allocator.free(v.fields);
                }
                allocator.free(variants.allocatedSlice());
            }

            // Resolve discriminant name from DW_AT_discr reference
            var discr_name: []const u8 = "";
            if (die.has_discr_ref) {
                if (type_map.get(die.discr_ref)) |discr_die| {
                    discr_name = discr_die.name orelse "";
                }
            }

            // Find child DW_TAG_variant DIEs
            var iter = type_map.iterator();
            while (iter.next()) |entry| {
                const variant_die = entry.value_ptr;
                if (variant_die.tag == DW_TAG_variant and variant_die.has_parent and variant_die.parent_offset == type_ref) {
                    // Collect member fields within this variant
                    var fields = std.ArrayListUnmanaged(StructField).empty;
                    errdefer allocator.free(fields.allocatedSlice());

                    var member_iter = type_map.iterator();
                    while (member_iter.next()) |member_entry| {
                        const member_die = member_entry.value_ptr;
                        if (member_die.tag == DW_TAG_member and member_die.has_parent and member_die.parent_offset == entry.key_ptr.*) {
                            var mem_encoding: u8 = 0;
                            var mem_byte_size: u8 = 0;
                            var mem_type_name: []const u8 = "";
                            if (member_die.has_type_ref) {
                                if (type_map.get(member_die.type_ref)) |member_type| {
                                    mem_encoding = member_type.encoding;
                                    mem_byte_size = member_type.byte_size;
                                    mem_type_name = member_type.name orelse "";
                                }
                            }
                            try fields.append(allocator, .{
                                .name = member_die.name orelse "",
                                .offset = member_die.member_location,
                                .encoding = mem_encoding,
                                .byte_size = mem_byte_size,
                                .type_name = mem_type_name,
                            });
                        }
                    }

                    try variants.append(allocator, .{
                        .discr_value = variant_die.discr_value,
                        .name = variant_die.name orelse "",
                        .fields = try fields.toOwnedSlice(allocator),
                    });
                }
            }

            return TypeDescription{
                .kind = .tagged_union,
                .name = die.name orelse "",
                .byte_size = die.byte_size,
                .variants = try variants.toOwnedSlice(allocator),
                .discriminant_name = discr_name,
            };
        },
        DW_TAG_typedef => {
            // Follow the typedef to the underlying type
            if (die.has_type_ref) {
                var resolved = try resolveTypeDescriptionImpl(type_map, die.type_ref, allocator, depth + 1);
                // Keep the typedef name as the display name
                resolved.kind = .typedef_type;
                if (die.name) |n| {
                    resolved.name = n;
                }
                return resolved;
            }
            return TypeDescription{
                .kind = .typedef_type,
                .name = die.name orelse "",
            };
        },
        DW_TAG_const_type, DW_TAG_volatile_type, DW_TAG_restrict_type, DW_TAG_atomic_type => {
            // Transparent qualifier — follow to underlying type
            if (die.has_type_ref) {
                var resolved = try resolveTypeDescriptionImpl(type_map, die.type_ref, allocator, depth + 1);
                resolved.kind = .const_type;
                return resolved;
            }
            return TypeDescription{ .kind = .const_type, .name = "const" };
        },
        DW_TAG_subroutine_type => {
            // Function pointer type — resolve return type if available
            var ret_name: []const u8 = "void";
            if (die.has_type_ref) {
                const ret = try resolveTypeDescriptionImpl(type_map, die.type_ref, allocator, depth + 1);
                ret_name = ret.name;
            }
            return TypeDescription{
                .kind = .pointer,
                .name = die.name orelse "",
                .byte_size = 8,
                .pointee_name = ret_name,
            };
        },
        DW_TAG_inheritance => {
            // Inheritance records base class offset; resolve as struct-like
            return TypeDescription{
                .kind = .structure,
                .name = die.name orelse "",
                .byte_size = die.byte_size,
            };
        },
        DW_TAG_template_type_parameter, DW_TAG_template_value_parameter => {
            // Template parameters — skip, not a concrete type
            return TypeDescription{ .kind = .unknown, .name = die.name orelse "" };
        },
        DW_TAG_call_site, DW_TAG_call_site_parameter => {
            // Call site info — skip for now (future use)
            return TypeDescription{ .kind = .unknown, .name = "" };
        },
        DW_TAG_unspecified_type => {
            return TypeDescription{
                .kind = .unknown,
                .name = die.name orelse "void",
            };
        },
        else => {
            return TypeDescription{ .kind = .unknown, .name = die.name orelse "" };
        },
    }
}

/// Free a TypeDescription's allocated memory.
pub fn freeTypeDescription(desc: TypeDescription, allocator: std.mem.Allocator) void {
    if (desc.fields.len > 0) {
        allocator.free(desc.fields);
    }
    if (desc.enum_values.len > 0) {
        allocator.free(desc.enum_values);
    }
    if (desc.variants.len > 0) {
        for (desc.variants) |v| {
            if (v.fields.len > 0) {
                allocator.free(v.fields);
            }
        }
        allocator.free(desc.variants);
    }
}

/// Parse .debug_info to extract variable declarations (DW_TAG_variable and DW_TAG_formal_parameter).
pub fn parseVariables(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]VariableInfo {
    return parseVariablesEx(debug_info, debug_abbrev, debug_str, .{}, allocator);
}

/// Parse variables with optional DWARF 5 sections.
pub fn parseVariablesEx(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    allocator: std.mem.Allocator,
) ![]VariableInfo {
    var variables: std.ArrayListUnmanaged(VariableInfo) = .empty;
    errdefer {
        for (variables.items) |v| {
            allocator.free(v.location_expr);
        }
        variables.deinit(allocator);
    }

    if (debug_info.len < 11) return try variables.toOwnedSlice(allocator);

    var pos: usize = 0;

    // Compilation unit header
    const unit_length_32 = readU32(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
    var is_64bit = false;
    var unit_length: u64 = unit_length_32;
    if (unit_length_32 == 0xFFFFFFFF) {
        unit_length = readU64(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
        is_64bit = true;
    }
    const unit_end = pos + @as(usize, @intCast(unit_length));
    const cu_start = if (is_64bit) @as(usize, 12) else @as(usize, 4);

    const version = readU16(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);

    var address_size: u8 = 8;
    var abbrev_offset: u64 = undefined;
    if (version >= 5) {
        if (pos >= debug_info.len) return try variables.toOwnedSlice(allocator);
        pos += 1; // unit_type
        if (pos >= debug_info.len) return try variables.toOwnedSlice(allocator);
        address_size = debug_info[pos];
        pos += 1;
        abbrev_offset = if (is_64bit)
            readU64(debug_info, &pos) catch return try variables.toOwnedSlice(allocator)
        else
            readU32(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
    } else {
        abbrev_offset = if (is_64bit)
            readU64(debug_info, &pos) catch return try variables.toOwnedSlice(allocator)
        else
            readU32(debug_info, &pos) catch return try variables.toOwnedSlice(allocator);
        if (pos >= debug_info.len) return try variables.toOwnedSlice(allocator);
        address_size = debug_info[pos];
        pos += 1;
    }

    const abbrev_data = if (abbrev_offset < debug_abbrev.len)
        debug_abbrev[@intCast(abbrev_offset)..]
    else
        return try variables.toOwnedSlice(allocator);

    const abbrevs = parseAbbrevTable(abbrev_data, allocator) catch return try variables.toOwnedSlice(allocator);
    defer freeAbbrevTable(abbrevs, allocator);

    // Collect base type info by offset for type resolution
    const TypeInfo = struct { encoding: u8, byte_size: u8, name: []const u8 };
    var type_map = std.AutoHashMap(u64, TypeInfo).init(allocator);
    defer type_map.deinit();

    // First pass: collect base types
    {
        var scan_pos = pos;
        while (scan_pos < unit_end and scan_pos < debug_info.len) {
            const die_offset = scan_pos - cu_start; // offset relative to CU start
            const abbrev_code = readULEB128(debug_info, &scan_pos) catch break;
            if (abbrev_code == 0) continue;
            const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

            var t_name: ?[]const u8 = null;
            var t_encoding: u8 = 0;
            var t_byte_size: u8 = 0;

            for (abbrev.attributes) |attr| {
                if (attr.form == DW_FORM_implicit_const) continue;
                switch (attr.name) {
                    DW_AT_name => {
                        if (attr.form == DW_FORM_string) {
                            t_name = readNullTermString(debug_info, &scan_pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &scan_pos) catch break
                            else
                                readU32(debug_info, &scan_pos) catch break;
                            if (debug_str) |s| t_name = readStringAt(s, @intCast(str_offset));
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            const index = readFormIndex(debug_info, &scan_pos, attr.form) catch break;
                            t_name = resolveStrx(debug_str, extra.debug_str_offsets, 0, index, is_64bit);
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_encoding => {
                        if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                            t_encoding = debug_info[scan_pos];
                            scan_pos += 1;
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_byte_size => {
                        if (attr.form == DW_FORM_data1 and scan_pos < debug_info.len) {
                            t_byte_size = debug_info[scan_pos];
                            scan_pos += 1;
                        } else {
                            skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                        }
                    },
                    else => {
                        skipForm(debug_info, &scan_pos, attr.form, is_64bit) catch break;
                    },
                }
            }

            if (abbrev.tag == DW_TAG_base_type) {
                type_map.put(die_offset, .{
                    .encoding = t_encoding,
                    .byte_size = t_byte_size,
                    .name = t_name orelse "",
                }) catch {};
            }
        }
    }

    // Second pass: collect variables
    while (pos < unit_end and pos < debug_info.len) {
        const abbrev_code = readULEB128(debug_info, &pos) catch break;
        if (abbrev_code == 0) continue;
        const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

        var v_name: ?[]const u8 = null;
        var v_location: ?[]const u8 = null;
        var v_type_ref: u64 = 0;

        for (abbrev.attributes) |attr| {
            if (attr.form == DW_FORM_implicit_const) continue;
            switch (attr.name) {
                DW_AT_name => {
                    if (attr.form == DW_FORM_string) {
                        v_name = readNullTermString(debug_info, &pos);
                    } else if (attr.form == DW_FORM_strp) {
                        const str_offset = if (is_64bit)
                            readU64(debug_info, &pos) catch break
                        else
                            readU32(debug_info, &pos) catch break;
                        if (debug_str) |s| v_name = readStringAt(s, @intCast(str_offset));
                    } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                        attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                    {
                        const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                        v_name = resolveStrx(debug_str, extra.debug_str_offsets, 0, index, is_64bit);
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_location => {
                    if (attr.form == DW_FORM_exprloc) {
                        const loc_len = readULEB128(debug_info, &pos) catch break;
                        const loc_end = pos + @as(usize, @intCast(loc_len));
                        if (loc_end <= debug_info.len) {
                            v_location = debug_info[pos..loc_end];
                        }
                        pos = loc_end;
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_type => {
                    if (attr.form == DW_FORM_ref_sig8) {
                        // Type signature — skip for now (would need type_units to resolve)
                        pos += 8;
                    } else if (attr.form == DW_FORM_ref4) {
                        v_type_ref = readU32(debug_info, &pos) catch break;
                    } else if (attr.form == DW_FORM_ref1 and pos < debug_info.len) {
                        v_type_ref = debug_info[pos];
                        pos += 1;
                    } else if (attr.form == DW_FORM_ref2) {
                        v_type_ref = readU16(debug_info, &pos) catch break;
                    } else if (attr.form == DW_FORM_ref8) {
                        v_type_ref = readU64(debug_info, &pos) catch break;
                    } else if (attr.form == DW_FORM_ref_udata) {
                        v_type_ref = readULEB128(debug_info, &pos) catch break;
                    } else {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    }
                },
                else => {
                    skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                },
            }
        }

        if (abbrev.tag == DW_TAG_variable or abbrev.tag == DW_TAG_formal_parameter) {
            if (v_name) |name| {
                // Resolve type info from collected base types
                var encoding: u8 = 0;
                var byte_size: u8 = 0;
                var type_name: []const u8 = "";
                if (type_map.get(v_type_ref)) |ti| {
                    encoding = ti.encoding;
                    byte_size = ti.byte_size;
                    type_name = ti.name;
                }

                const loc_expr = if (v_location) |loc|
                    try allocator.dupe(u8, loc)
                else
                    try allocator.alloc(u8, 0);

                try variables.append(allocator, .{
                    .name = name,
                    .location_expr = loc_expr,
                    .type_encoding = encoding,
                    .type_byte_size = byte_size,
                    .type_name = type_name,
                    .scope = if (abbrev.tag == DW_TAG_formal_parameter) .argument else .local,
                });
            }
        }
    }

    return try variables.toOwnedSlice(allocator);
}

pub fn freeVariables(variables: []VariableInfo, allocator: std.mem.Allocator) void {
    for (variables) |v| {
        allocator.free(v.location_expr);
        if (v.type_desc) |td| {
            freeTypeDescription(td, allocator);
        }
    }
    allocator.free(variables);
}

// ── Scoped Variable Parsing ────────────────────────────────────────────

pub const ScopedVariableResult = struct {
    variables: []VariableInfo,
    frame_base_expr: []const u8, // borrowed from debug_info, not allocated
};

/// Parse variables scoped to the subprogram containing `target_pc`.
/// Iterates over all compilation units to find the matching function.
/// Only returns variables/parameters that are direct children of the matching function DIE.
/// Also captures the function's DW_AT_frame_base expression.
pub fn parseScopedVariables(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    target_pc: u64,
    allocator: std.mem.Allocator,
) !ScopedVariableResult {
    var variables: std.ArrayListUnmanaged(VariableInfo) = .empty;
    errdefer {
        for (variables.items) |v| {
            allocator.free(v.location_expr);
            if (v.type_desc) |td| {
                freeTypeDescription(td, allocator);
            }
        }
        variables.deinit(allocator);
    }

    var frame_base_expr: []const u8 = &.{};

    if (debug_info.len < 11) return .{ .variables = try variables.toOwnedSlice(allocator), .frame_base_expr = frame_base_expr };

    const DW_AT_str_offsets_base_c: u64 = 0x72;
    const DW_AT_addr_base_c: u64 = 0x73;

    var cu_pos: usize = 0;
    var found = false;

    // Iterate over all compilation units
    while (cu_pos < debug_info.len and !found) {
        var pos = cu_pos;

        // CU header
        const unit_length_32 = readU32(debug_info, &pos) catch break;
        var is_64bit = false;
        var unit_length: u64 = unit_length_32;
        if (unit_length_32 == 0xFFFFFFFF) {
            unit_length = readU64(debug_info, &pos) catch break;
            is_64bit = true;
        }
        if (unit_length == 0) break;
        const unit_end = pos + @as(usize, @intCast(unit_length));

        // Advance cu_pos for next iteration
        cu_pos = unit_end;

        const version = readU16(debug_info, &pos) catch continue;

        var address_size: u8 = 8;
        var abbrev_offset: u64 = undefined;
        if (version >= 5) {
            if (pos >= debug_info.len) continue;
            pos += 1; // unit_type
            if (pos >= debug_info.len) continue;
            address_size = debug_info[pos];
            pos += 1;
            abbrev_offset = if (is_64bit)
                readU64(debug_info, &pos) catch continue
            else
                readU32(debug_info, &pos) catch continue;
        } else {
            abbrev_offset = if (is_64bit)
                readU64(debug_info, &pos) catch continue
            else
                readU32(debug_info, &pos) catch continue;
            if (pos >= debug_info.len) continue;
            address_size = debug_info[pos];
            pos += 1;
        }

        const abbrev_data = if (abbrev_offset < debug_abbrev.len)
            debug_abbrev[@intCast(abbrev_offset)..]
        else
            continue;

        const abbrevs = parseAbbrevTable(abbrev_data, allocator) catch continue;
        defer freeAbbrevTable(abbrevs, allocator);

        // DWARF 5: extract str_offsets_base and addr_base from the CU DIE
        var str_offsets_base: u64 = 0;
        var addr_base: u64 = 0;
        var rnglists_base: u64 = 0;
        var loclists_base: u64 = 0;
        var cu_low_pc: u64 = 0;

        if (version >= 5) {
            var base_pos = pos;
            const first_code = readULEB128(debug_info, &base_pos) catch 0;
            if (first_code != 0) {
                if (findAbbrev(abbrevs, first_code)) |first_abbrev| {
                    for (first_abbrev.attributes) |attr| {
                        if (attr.form == DW_FORM_implicit_const) continue;

                        if (attr.name == DW_AT_str_offsets_base_c) {
                            if (attr.form == DW_FORM_sec_offset) {
                                str_offsets_base = if (is_64bit)
                                    readU64(debug_info, &base_pos) catch 0
                                else
                                    readU32(debug_info, &base_pos) catch 0;
                            } else {
                                skipForm(debug_info, &base_pos, attr.form, is_64bit) catch break;
                            }
                        } else if (attr.name == DW_AT_addr_base_c) {
                            if (attr.form == DW_FORM_sec_offset) {
                                addr_base = if (is_64bit)
                                    readU64(debug_info, &base_pos) catch 0
                                else
                                    readU32(debug_info, &base_pos) catch 0;
                            } else {
                                skipForm(debug_info, &base_pos, attr.form, is_64bit) catch break;
                            }
                        } else if (attr.name == DW_AT_rnglists_base) {
                            if (attr.form == DW_FORM_sec_offset) {
                                rnglists_base = if (is_64bit)
                                    readU64(debug_info, &base_pos) catch 0
                                else
                                    readU32(debug_info, &base_pos) catch 0;
                            } else {
                                skipForm(debug_info, &base_pos, attr.form, is_64bit) catch break;
                            }
                        } else if (attr.name == DW_AT_loclists_base) {
                            if (attr.form == DW_FORM_sec_offset) {
                                loclists_base = if (is_64bit)
                                    readU64(debug_info, &base_pos) catch 0
                                else
                                    readU32(debug_info, &base_pos) catch 0;
                            } else {
                                skipForm(debug_info, &base_pos, attr.form, is_64bit) catch break;
                            }
                        } else if (attr.name == DW_AT_low_pc) {
                            if (attr.form == DW_FORM_addr) {
                                cu_low_pc = if (address_size == 8)
                                    readU64(debug_info, &base_pos) catch 0
                                else
                                    readU32(debug_info, &base_pos) catch 0;
                            } else if (attr.form == DW_FORM_addrx or attr.form == DW_FORM_addrx1 or
                                attr.form == DW_FORM_addrx2 or attr.form == DW_FORM_addrx4)
                            {
                                const index = readFormIndex(debug_info, &base_pos, attr.form) catch 0;
                                cu_low_pc = resolveAddrx(extra.debug_addr, addr_base, index, address_size);
                            } else {
                                skipForm(debug_info, &base_pos, attr.form, is_64bit) catch break;
                            }
                        } else {
                            skipForm(debug_info, &base_pos, attr.form, is_64bit) catch break;
                        }
                    }
                }
            }
        }

        // First pass: collect all type DIEs into a rich type map
        var type_map = collectTypeDies(
            debug_info,
            abbrevs,
            debug_str,
            extra,
            str_offsets_base,
            is_64bit,
            address_size,
            pos,
            unit_end,
            allocator,
        ) catch continue;
        defer type_map.deinit();

        // Second pass: walk DIEs tracking depth to find the target subprogram
        var depth: u32 = 0;
        var in_target_func = false;
        var target_func_depth: u32 = 0;

        while (pos < unit_end and pos < debug_info.len) {
            const abbrev_code = readULEB128(debug_info, &pos) catch break;
            if (abbrev_code == 0) {
                // Null DIE — end of children at this level
                if (in_target_func and depth <= target_func_depth) {
                    // We've exited the target function scope
                    found = true;
                    break;
                }
                if (depth > 0) depth -= 1;
                continue;
            }

            const abbrev = findAbbrev(abbrevs, abbrev_code) orelse break;

            // Parse attributes for this DIE
            var die_name: ?[]const u8 = null;
            var die_location: ?[]const u8 = null;
            var die_type_ref: u64 = 0;
            var die_low_pc: u64 = 0;
            var die_high_pc: u64 = 0;
            var die_high_pc_is_offset = false;
            var die_frame_base: ?[]const u8 = null;
            var die_ranges_offset: ?u64 = null;
            var die_ranges_is_rnglistx = false;

            for (abbrev.attributes) |attr| {
                if (attr.form == DW_FORM_implicit_const) continue;
                switch (attr.name) {
                    DW_AT_name => {
                        if (attr.form == DW_FORM_string) {
                            die_name = readNullTermString(debug_info, &pos);
                        } else if (attr.form == DW_FORM_strp) {
                            const str_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                            if (debug_str) |s| die_name = readStringAt(s, @intCast(str_offset));
                        } else if (attr.form == DW_FORM_strx or attr.form == DW_FORM_strx1 or
                            attr.form == DW_FORM_strx2 or attr.form == DW_FORM_strx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            die_name = resolveStrx(debug_str, extra.debug_str_offsets, str_offsets_base, index, is_64bit);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_location => {
                        if (attr.form == DW_FORM_exprloc) {
                            const loc_len = readULEB128(debug_info, &pos) catch break;
                            const loc_end = pos + @as(usize, @intCast(loc_len));
                            if (loc_end <= debug_info.len) {
                                die_location = debug_info[pos..loc_end];
                            }
                            pos = loc_end;
                        } else if (attr.form == DW_FORM_sec_offset) {
                            // DWARF 4: offset into .debug_loc section
                            const loc_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                            if (extra.debug_loc) |loc_data| {
                                die_location = location.evalLocationList(
                                    loc_data,
                                    loc_offset,
                                    target_pc,
                                    cu_low_pc,
                                );
                            }
                        } else if (attr.form == DW_FORM_loclistx) {
                            // DWARF 5: index into .debug_loclists section
                            const loc_index = readULEB128(debug_info, &pos) catch break;
                            if (extra.debug_loclists) |loclists_data| {
                                // Resolve the offset from the index via the offset table
                                // The offset table starts at loclists_base, each entry is 4 bytes (32-bit) or 8 bytes (64-bit)
                                const entry_size: u64 = if (is_64bit) 8 else 4;
                                const table_offset = loclists_base + loc_index * entry_size;
                                if (table_offset + entry_size <= loclists_data.len) {
                                    const list_offset = if (is_64bit)
                                        std.mem.readInt(u64, loclists_data[@intCast(table_offset)..][0..8], .little)
                                    else
                                        @as(u64, std.mem.readInt(u32, loclists_data[@intCast(table_offset)..][0..4], .little));
                                    // The actual offset is relative to loclists_base
                                    die_location = location.evalLocationListDwarf5(
                                        loclists_data,
                                        loclists_base + list_offset,
                                        target_pc,
                                        cu_low_pc,
                                        extra.debug_addr,
                                        addr_base,
                                    );
                                }
                            }
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_frame_base => {
                        if (attr.form == DW_FORM_exprloc) {
                            const fb_len = readULEB128(debug_info, &pos) catch break;
                            const fb_end = pos + @as(usize, @intCast(fb_len));
                            if (fb_end <= debug_info.len) {
                                die_frame_base = debug_info[pos..fb_end];
                            }
                            pos = fb_end;
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_type => {
                        if (attr.form == DW_FORM_ref_sig8) {
                            pos += 8; // Type signature — skip for now
                        } else if (attr.form == DW_FORM_ref4) {
                            die_type_ref = readU32(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref1 and pos < debug_info.len) {
                            die_type_ref = debug_info[pos];
                            pos += 1;
                        } else if (attr.form == DW_FORM_ref2) {
                            die_type_ref = readU16(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref8) {
                            die_type_ref = readU64(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_ref_udata) {
                            die_type_ref = readULEB128(debug_info, &pos) catch break;
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_low_pc => {
                        if (attr.form == DW_FORM_addr) {
                            if (address_size == 8) {
                                die_low_pc = readU64(debug_info, &pos) catch break;
                            } else {
                                die_low_pc = readU32(debug_info, &pos) catch break;
                            }
                        } else if (attr.form == DW_FORM_addrx or attr.form == DW_FORM_addrx1 or
                            attr.form == DW_FORM_addrx2 or attr.form == DW_FORM_addrx4)
                        {
                            const index = readFormIndex(debug_info, &pos, attr.form) catch break;
                            die_low_pc = resolveAddrx(extra.debug_addr, addr_base, index, address_size);
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_high_pc => {
                        if (attr.form == DW_FORM_addr) {
                            if (address_size == 8) {
                                die_high_pc = readU64(debug_info, &pos) catch break;
                            } else {
                                die_high_pc = readU32(debug_info, &pos) catch break;
                            }
                        } else if (attr.form == DW_FORM_data1 or attr.form == DW_FORM_data2 or
                            attr.form == DW_FORM_data4 or attr.form == DW_FORM_data8 or
                            attr.form == DW_FORM_udata or attr.form == DW_FORM_sdata)
                        {
                            die_high_pc_is_offset = true;
                            if (attr.form == DW_FORM_data1 and pos < debug_info.len) {
                                die_high_pc = debug_info[pos];
                                pos += 1;
                            } else if (attr.form == DW_FORM_data2) {
                                die_high_pc = readU16(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_data4) {
                                die_high_pc = readU32(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_data8) {
                                die_high_pc = readU64(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_udata) {
                                die_high_pc = readULEB128(debug_info, &pos) catch break;
                            } else if (attr.form == DW_FORM_sdata) {
                                const s = readSLEB128(debug_info, &pos) catch break;
                                die_high_pc = @intCast(s);
                            }
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    DW_AT_ranges => {
                        if (attr.form == DW_FORM_sec_offset) {
                            die_ranges_offset = if (is_64bit)
                                readU64(debug_info, &pos) catch break
                            else
                                readU32(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_rnglistx) {
                            die_ranges_offset = readULEB128(debug_info, &pos) catch break;
                            die_ranges_is_rnglistx = true;
                        } else if (attr.form == DW_FORM_data4) {
                            die_ranges_offset = readU32(debug_info, &pos) catch break;
                        } else if (attr.form == DW_FORM_data8) {
                            die_ranges_offset = readU64(debug_info, &pos) catch break;
                        } else {
                            skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                        }
                    },
                    else => {
                        skipForm(debug_info, &pos, attr.form, is_64bit) catch break;
                    },
                }
            }

            if (die_high_pc_is_offset) {
                die_high_pc = die_low_pc + die_high_pc;
            }

            // Check if this is the target subprogram
            if (!in_target_func and abbrev.tag == DW_TAG_subprogram) {
                const pc_in_func = if (die_low_pc > 0 or die_high_pc > 0)
                    die_low_pc <= target_pc and target_pc < die_high_pc
                else if (die_ranges_offset) |rng_off|
                    pcInRangesEx(extra, version, rng_off, die_ranges_is_rnglistx, rnglists_base, target_pc, cu_low_pc, addr_base, address_size)
                else
                    false;

                if (pc_in_func) {
                    in_target_func = true;
                    target_func_depth = depth;
                    if (die_frame_base) |fb| {
                        frame_base_expr = fb;
                    }
                }
            }

            // Collect variables/parameters inside the target function
            if (in_target_func and (abbrev.tag == DW_TAG_variable or abbrev.tag == DW_TAG_formal_parameter)) {
                if (die_name) |name| {
                    // Resolve type through the full type graph
                    var encoding: u8 = 0;
                    var byte_size: u8 = 0;
                    var type_name: []const u8 = "";
                    var type_desc: ?TypeDescription = null;

                    if (die_type_ref != 0) {
                        if (type_map.get(die_type_ref)) |type_die| {
                            encoding = type_die.encoding;
                            byte_size = type_die.byte_size;
                            type_name = type_die.name orelse "";

                            // Build rich type description for composite types
                            if (type_die.tag != DW_TAG_base_type) {
                                type_desc = resolveTypeDescription(&type_map, die_type_ref, allocator) catch null;
                                if (type_desc) |td| {
                                    // Use resolved info for display
                                    if (td.byte_size > 0) byte_size = td.byte_size;
                                    if (td.name.len > 0) type_name = td.name;
                                    if (td.encoding > 0) encoding = td.encoding;
                                }
                            }
                        }
                    }

                    const loc_expr = if (die_location) |loc|
                        try allocator.dupe(u8, loc)
                    else
                        try allocator.alloc(u8, 0);

                    try variables.append(allocator, .{
                        .name = name,
                        .location_expr = loc_expr,
                        .type_encoding = encoding,
                        .type_byte_size = byte_size,
                        .type_name = type_name,
                        .scope = if (abbrev.tag == DW_TAG_formal_parameter) .argument else .local,
                        .type_desc = type_desc,
                    });
                }
            }

            // Track depth
            if (abbrev.has_children) {
                depth += 1;
            }
        }

        // If we found the target function, we're done with CU iteration
        if (in_target_func) found = true;
    }

    return .{
        .variables = try variables.toOwnedSlice(allocator),
        .frame_base_expr = frame_base_expr,
    };
}

pub fn freeScopedVariables(result: ScopedVariableResult, allocator: std.mem.Allocator) void {
    freeVariables(result.variables, allocator);
}

// ── Helper Functions ───────────────────────────────────────────────────

fn findAbbrev(abbrevs: []const AbbrevEntry, code: u64) ?*const AbbrevEntry {
    for (abbrevs) |*entry| {
        if (entry.code == code) return entry;
    }
    return null;
}

fn readNullTermString(data: []const u8, pos: *usize) []const u8 {
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0) {
        pos.* += 1;
    }
    const result = data[start..pos.*];
    if (pos.* < data.len) pos.* += 1; // Skip null terminator
    return result;
}

fn readStringAt(data: []const u8, offset: usize) ?[]const u8 {
    if (offset >= data.len) return null;
    var end = offset;
    while (end < data.len and data[end] != 0) {
        end += 1;
    }
    return data[offset..end];
}

fn readU16(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 2 > data.len) return error.OutOfBounds;
    const result = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return result;
}

fn readU32(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.OutOfBounds;
    const result = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return result;
}

fn readU64(data: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > data.len) return error.OutOfBounds;
    const result = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return result;
}

fn skipForm(data: []const u8, pos: *usize, form: u64, is_64bit: bool) !void {
    switch (form) {
        DW_FORM_addr => pos.* += 8, // Assuming 64-bit addresses
        DW_FORM_data1, DW_FORM_ref1, DW_FORM_flag, DW_FORM_strx1, DW_FORM_addrx1 => pos.* += 1,
        DW_FORM_data2, DW_FORM_ref2, DW_FORM_strx2, DW_FORM_addrx2 => pos.* += 2,
        DW_FORM_data4, DW_FORM_ref4, DW_FORM_strx4, DW_FORM_addrx4 => pos.* += 4,
        DW_FORM_data8, DW_FORM_ref8, DW_FORM_ref_sig8 => pos.* += 8,
        DW_FORM_data16 => pos.* += 16,
        DW_FORM_string => {
            _ = readNullTermString(data, pos);
        },
        DW_FORM_strp, DW_FORM_sec_offset, DW_FORM_ref_addr, DW_FORM_line_strp => {
            if (is_64bit) {
                pos.* += 8;
            } else {
                pos.* += 4;
            }
        },
        DW_FORM_sdata => {
            _ = try readSLEB128(data, pos);
        },
        DW_FORM_udata, DW_FORM_ref_udata, DW_FORM_strx, DW_FORM_addrx, DW_FORM_rnglistx, DW_FORM_loclistx => {
            _ = try readULEB128(data, pos);
        },
        DW_FORM_block1 => {
            if (pos.* < data.len) {
                const len = data[pos.*];
                pos.* += 1 + len;
            }
        },
        DW_FORM_block2 => {
            const len = try readU16(data, pos);
            pos.* += len;
        },
        DW_FORM_block4 => {
            const len = try readU32(data, pos);
            pos.* += @intCast(len);
        },
        DW_FORM_block, DW_FORM_exprloc => {
            const len = try readULEB128(data, pos);
            pos.* += @intCast(len);
        },
        DW_FORM_flag_present => {}, // No data, presence is the value
        DW_FORM_implicit_const => {}, // Value in abbrev table
        DW_FORM_indirect => {
            // Read the actual form as a ULEB128, then dispatch
            const actual_form = try readULEB128(data, pos);
            try skipForm(data, pos, actual_form, is_64bit);
        },
        else => {
            // Unknown form - cannot determine size
            return error.UnknownForm;
        },
    }
    if (pos.* > data.len) return error.OutOfBounds;
}

// ── .debug_names Accelerated Lookup (DWARF5 Section 6.1.1) ──────────────

/// Result from a .debug_names lookup.
pub const DebugNameEntry = struct {
    die_offset: u64,
    cu_index: u32,
    tag: u64,
};

/// Parsed .debug_names section header and lookup tables.
pub const DebugNamesIndex = struct {
    bucket_count: u32,
    name_count: u32,
    // Raw section data and offsets into it
    data: []const u8,
    debug_str: ?[]const u8,
    // Offsets to the start of each table within data
    buckets_offset: usize,
    hashes_offset: usize,
    string_offsets_offset: usize,
    entry_offsets_offset: usize,
    entry_pool_offset: usize,
    // Abbreviation table for entry pool decoding
    abbrev_table: []const NameAbbrev,
    abbrev_table_allocated: bool = false,

    pub fn deinit(self: *DebugNamesIndex, allocator: std.mem.Allocator) void {
        if (self.abbrev_table_allocated) {
            allocator.free(self.abbrev_table);
        }
    }

    /// Look up a name by string and return matching entries.
    pub fn lookup(self: *const DebugNamesIndex, name: []const u8, allocator: std.mem.Allocator) ![]DebugNameEntry {
        if (self.bucket_count == 0 or self.name_count == 0) return &.{};

        const hash = debugNamesHash(name);
        const bucket_idx = hash % self.bucket_count;

        // Read bucket value — index into hashes/string_offsets/entry_offsets (1-based, 0 = empty)
        const bucket_pos = self.buckets_offset + @as(usize, bucket_idx) * 4;
        if (bucket_pos + 4 > self.data.len) return &.{};
        const name_idx_start = std.mem.readInt(u32, self.data[bucket_pos..][0..4], .little);
        if (name_idx_start == 0) return &.{};

        var results = std.ArrayListUnmanaged(DebugNameEntry).empty;
        errdefer results.deinit(allocator);

        // Scan entries in this bucket until we hit a different bucket or end
        var name_idx: u32 = name_idx_start;
        while (name_idx <= self.name_count) : (name_idx += 1) {
            // Check hash matches
            const hash_pos = self.hashes_offset + @as(usize, name_idx - 1) * 4;
            if (hash_pos + 4 > self.data.len) break;
            const entry_hash = std.mem.readInt(u32, self.data[hash_pos..][0..4], .little);

            // Check if we've moved past this bucket
            if ((entry_hash % self.bucket_count) != bucket_idx) break;

            // Only check string if hash matches exactly
            if (entry_hash != hash) continue;

            // Read string offset and compare name
            const str_off_pos = self.string_offsets_offset + @as(usize, name_idx - 1) * 4;
            if (str_off_pos + 4 > self.data.len) continue;
            const str_offset = std.mem.readInt(u32, self.data[str_off_pos..][0..4], .little);

            const entry_name = if (self.debug_str) |str_data| readStringAt(str_data, str_offset) else null;
            if (entry_name == null) continue;
            if (!std.mem.eql(u8, entry_name.?, name)) continue;

            // Match! Read entry offset and parse entry pool
            const entry_off_pos = self.entry_offsets_offset + @as(usize, name_idx - 1) * 4;
            if (entry_off_pos + 4 > self.data.len) continue;
            const entry_offset = std.mem.readInt(u32, self.data[entry_off_pos..][0..4], .little);

            var pool_pos = self.entry_pool_offset + entry_offset;
            // Parse entries until sentinel (0 abbrev code)
            while (pool_pos < self.data.len) {
                const abbrev_code = readULEB128(self.data, &pool_pos) catch break;
                if (abbrev_code == 0) break;

                // Look up abbreviation
                const abbrev = findNameAbbrev(self.abbrev_table, @intCast(abbrev_code));
                if (abbrev == null) break;
                const ab = abbrev.?;

                var die_offset: u64 = 0;
                var cu_idx: u32 = 0;
                for (ab.attrs) |attr| {
                    switch (attr.form) {
                        DW_FORM_data4 => {
                            if (pool_pos + 4 > self.data.len) break;
                            const val = std.mem.readInt(u32, self.data[pool_pos..][0..4], .little);
                            pool_pos += 4;
                            if (attr.idx == DW_IDX_die_offset) {
                                die_offset = val;
                            } else if (attr.idx == DW_IDX_compile_unit) {
                                cu_idx = val;
                            }
                        },
                        DW_FORM_data8 => {
                            if (pool_pos + 8 > self.data.len) break;
                            const val = std.mem.readInt(u64, self.data[pool_pos..][0..8], .little);
                            pool_pos += 8;
                            if (attr.idx == DW_IDX_die_offset) {
                                die_offset = val;
                            }
                        },
                        DW_FORM_ref4 => {
                            if (pool_pos + 4 > self.data.len) break;
                            const val = std.mem.readInt(u32, self.data[pool_pos..][0..4], .little);
                            pool_pos += 4;
                            if (attr.idx == DW_IDX_die_offset) {
                                die_offset = val;
                            }
                        },
                        DW_FORM_udata => {
                            const val = readULEB128(self.data, &pool_pos) catch break;
                            if (attr.idx == DW_IDX_die_offset) {
                                die_offset = val;
                            } else if (attr.idx == DW_IDX_compile_unit) {
                                cu_idx = @intCast(val);
                            }
                        },
                        DW_FORM_data1 => {
                            if (pool_pos >= self.data.len) break;
                            const val = self.data[pool_pos];
                            pool_pos += 1;
                            if (attr.idx == DW_IDX_compile_unit) {
                                cu_idx = val;
                            }
                        },
                        DW_FORM_data2 => {
                            if (pool_pos + 2 > self.data.len) break;
                            const val = std.mem.readInt(u16, self.data[pool_pos..][0..2], .little);
                            pool_pos += 2;
                            if (attr.idx == DW_IDX_compile_unit) {
                                cu_idx = val;
                            }
                        },
                        else => {
                            // Unknown form — skip using generic skipForm
                            skipForm(self.data, &pool_pos, attr.form, false) catch break;
                        },
                    }
                }

                try results.append(allocator, .{
                    .die_offset = die_offset,
                    .cu_index = cu_idx,
                    .tag = ab.tag,
                });
            }
        }

        return try results.toOwnedSlice(allocator);
    }
};

// .debug_names index form constants
const DW_IDX_compile_unit: u64 = 1;
const DW_IDX_type_unit: u64 = 2;
const DW_IDX_die_offset: u64 = 3;
const DW_IDX_parent: u64 = 4;
const DW_IDX_type_hash: u64 = 5;

const NameAbbrevAttr = struct {
    idx: u64,
    form: u64,
};

const NameAbbrev = struct {
    code: u32,
    tag: u64,
    attrs: []const NameAbbrevAttr,
};

fn findNameAbbrev(table: []const NameAbbrev, code: u32) ?NameAbbrev {
    for (table) |ab| {
        if (ab.code == code) return ab;
    }
    return null;
}

/// DWARF5 .debug_names hash function (DJB hash)
fn debugNamesHash(name: []const u8) u32 {
    var h: u32 = 5381;
    for (name) |c| {
        h = h *% 33 +% c;
    }
    return h;
}

/// Parse a .debug_names section into a DebugNamesIndex for accelerated lookup.
pub fn parseDebugNames(
    data: []const u8,
    debug_str: ?[]const u8,
    allocator: std.mem.Allocator,
) !DebugNamesIndex {
    if (data.len < 24) return error.TooShort;

    var pos: usize = 0;

    // Unit length (4 bytes for 32-bit DWARF, 12 for 64-bit)
    const unit_length_raw = readU32(data, &pos) catch return error.TooShort;
    const is_64bit = unit_length_raw == 0xFFFFFFFF;
    if (is_64bit) {
        _ = readU64(data, &pos) catch return error.TooShort;
    }

    // Version (should be 5)
    const version = readU16(data, &pos) catch return error.TooShort;
    if (version != 5) return error.UnsupportedVersion;

    // Padding (2 bytes)
    _ = readU16(data, &pos) catch return error.TooShort;

    // Counts
    const comp_unit_count = readU32(data, &pos) catch return error.TooShort;
    const local_type_unit_count = readU32(data, &pos) catch return error.TooShort;
    const foreign_type_unit_count = readU32(data, &pos) catch return error.TooShort;
    const bucket_count = readU32(data, &pos) catch return error.TooShort;
    const name_count = readU32(data, &pos) catch return error.TooShort;
    const abbrev_table_size = readU32(data, &pos) catch return error.TooShort;

    // Skip augmentation string (4 bytes size + string)
    // The augmentation string length is included in the header
    // For standard .debug_names, augmentation is 0 bytes
    // We've already read all the header fields.

    // Compute table offsets:
    // CU offsets table
    const cu_offsets_start = pos;
    const offset_size: usize = if (is_64bit) 8 else 4;
    pos = cu_offsets_start + @as(usize, comp_unit_count) * offset_size;

    // Local TU offsets table
    pos += @as(usize, local_type_unit_count) * offset_size;

    // Foreign TU signatures table
    pos += @as(usize, foreign_type_unit_count) * 8;

    // Buckets table
    const buckets_offset = pos;
    pos += @as(usize, bucket_count) * 4;

    // Hashes table
    const hashes_offset = pos;
    pos += @as(usize, name_count) * 4;

    // String offsets table
    const string_offsets_offset = pos;
    pos += @as(usize, name_count) * offset_size;

    // Entry offsets table
    const entry_offsets_offset = pos;
    pos += @as(usize, name_count) * offset_size;

    // Abbreviation table
    const abbrev_start = pos;
    const abbrev_end = abbrev_start + abbrev_table_size;

    // Parse abbreviation table
    var abbrevs = std.ArrayListUnmanaged(NameAbbrev).empty;
    errdefer {
        for (abbrevs.items) |ab| {
            allocator.free(ab.attrs);
        }
        abbrevs.deinit(allocator);
    }

    var abbrev_pos = abbrev_start;
    while (abbrev_pos < abbrev_end and abbrev_pos < data.len) {
        const code = readULEB128(data, &abbrev_pos) catch break;
        if (code == 0) break;
        const tag = readULEB128(data, &abbrev_pos) catch break;

        var attrs = std.ArrayListUnmanaged(NameAbbrevAttr).empty;
        errdefer attrs.deinit(allocator);

        while (abbrev_pos < data.len) {
            const idx = readULEB128(data, &abbrev_pos) catch break;
            const form = readULEB128(data, &abbrev_pos) catch break;
            if (idx == 0 and form == 0) break;
            try attrs.append(allocator, .{ .idx = idx, .form = form });
        }

        try abbrevs.append(allocator, .{
            .code = @intCast(code),
            .tag = tag,
            .attrs = try attrs.toOwnedSlice(allocator),
        });
    }

    // Entry pool starts after abbreviation table
    const entry_pool_offset = abbrev_end;

    return .{
        .bucket_count = bucket_count,
        .name_count = name_count,
        .data = data,
        .debug_str = debug_str,
        .buckets_offset = buckets_offset,
        .hashes_offset = hashes_offset,
        .string_offsets_offset = string_offsets_offset,
        .entry_offsets_offset = entry_offsets_offset,
        .entry_pool_offset = entry_pool_offset,
        .abbrev_table = try abbrevs.toOwnedSlice(allocator),
        .abbrev_table_allocated = true,
    };
}

// ── Type Units (DWARF5 Section 7.5.1.2) ────────────────────────────────

/// A parsed type unit entry mapping type signature to type DIE offset.
pub const TypeUnitEntry = struct {
    type_signature: u64,
    type_offset: u64,
    cu_offset: u64,
};

/// Scan .debug_info for type unit headers (DW_UT_type / DW_UT_split_type)
/// and build a mapping from type signature to DIE offset.
pub fn parseTypeUnits(
    debug_info: []const u8,
    allocator: std.mem.Allocator,
) ![]TypeUnitEntry {
    var entries = std.ArrayListUnmanaged(TypeUnitEntry).empty;
    errdefer entries.deinit(allocator);

    if (debug_info.len < 11) return try entries.toOwnedSlice(allocator);

    var cu_pos: usize = 0;
    while (cu_pos < debug_info.len) {
        const cu_start = cu_pos;

        // Read CU header
        const unit_length_raw = readU32(debug_info, &cu_pos) catch break;
        const is_64bit = unit_length_raw == 0xFFFFFFFF;
        const unit_length: u64 = if (is_64bit)
            readU64(debug_info, &cu_pos) catch break
        else
            unit_length_raw;
        const unit_end = cu_pos + @as(usize, @intCast(unit_length));

        const version = readU16(debug_info, &cu_pos) catch break;

        if (version >= 5) {
            if (cu_pos >= debug_info.len) break;
            const unit_type = debug_info[cu_pos];
            cu_pos += 1;

            if (unit_type == DW_UT_type or unit_type == DW_UT_split_type) {
                // address_size
                cu_pos += 1;
                // debug_abbrev_offset
                if (is_64bit) {
                    _ = readU64(debug_info, &cu_pos) catch break;
                } else {
                    _ = readU32(debug_info, &cu_pos) catch break;
                }
                // type_signature (8 bytes)
                const type_sig = readU64(debug_info, &cu_pos) catch break;
                // type_offset (4 or 8 bytes, relative to CU start)
                const type_off: u64 = if (is_64bit)
                    readU64(debug_info, &cu_pos) catch break
                else
                    readU32(debug_info, &cu_pos) catch break;

                try entries.append(allocator, .{
                    .type_signature = type_sig,
                    .type_offset = type_off,
                    .cu_offset = cu_start,
                });
            }
        }

        cu_pos = unit_end;
    }

    return try entries.toOwnedSlice(allocator);
}

/// Look up a type unit by its signature (used for DW_FORM_ref_sig8 resolution).
pub fn findTypeUnitBySignature(entries: []const TypeUnitEntry, signature: u64) ?TypeUnitEntry {
    for (entries) |entry| {
        if (entry.type_signature == signature) return entry;
    }
    return null;
}

// ── Split DWARF Detection (DWARF5 Section 7.3.2) ───────────────────────

/// Information about a skeleton CU that references a .dwo file.
pub const SkeletonCuInfo = struct {
    dwo_name: []const u8,
    comp_dir: []const u8 = "",
    dwo_id: u64 = 0,
    has_dwo_id: bool = false,
};

/// Scan .debug_info for skeleton CUs and extract .dwo file references.
/// Returns a list of skeleton CU entries that need external .dwo loading.
pub fn detectSplitDwarf(
    debug_info: []const u8,
    debug_abbrev: []const u8,
    debug_str: ?[]const u8,
    extra: ExtraSections,
    allocator: std.mem.Allocator,
) ![]SkeletonCuInfo {
    var skeletons = std.ArrayListUnmanaged(SkeletonCuInfo).empty;
    errdefer skeletons.deinit(allocator);

    if (debug_info.len < 11) return try skeletons.toOwnedSlice(allocator);

    var cu_pos: usize = 0;
    while (cu_pos < debug_info.len) {
        const cu_start = cu_pos;
        // Read CU header
        const unit_length_raw = readU32(debug_info, &cu_pos) catch break;
        const is_64bit = unit_length_raw == 0xFFFFFFFF;
        const unit_length: u64 = if (is_64bit)
            readU64(debug_info, &cu_pos) catch break
        else
            unit_length_raw;
        const unit_end = cu_pos + @as(usize, @intCast(unit_length));

        const version = readU16(debug_info, &cu_pos) catch break;

        // DWARF5: version, unit_type, address_size, debug_abbrev_offset
        var is_skeleton = false;
        if (version >= 5) {
            if (cu_pos >= debug_info.len) break;
            const unit_type = debug_info[cu_pos];
            cu_pos += 1;
            is_skeleton = (unit_type == DW_UT_skeleton);
            // address_size
            cu_pos += 1;
            // debug_abbrev_offset
            if (is_64bit) {
                _ = readU64(debug_info, &cu_pos) catch break;
            } else {
                _ = readU32(debug_info, &cu_pos) catch break;
            }
            // For skeleton/split_compile, dwo_id follows
            if (is_skeleton or unit_type == DW_UT_split_compile) {
                _ = readU64(debug_info, &cu_pos) catch break;
            }
        } else {
            // DWARF4: debug_abbrev_offset, address_size
            if (is_64bit) {
                _ = readU64(debug_info, &cu_pos) catch break;
            } else {
                _ = readU32(debug_info, &cu_pos) catch break;
            }
            cu_pos += 1; // address_size
        }

        // Parse the CU root DIE attributes looking for dwo_name
        const abbrev_offset_for_cu = blk: {
            var temp_pos: usize = cu_start;
            _ = readU32(debug_info, &temp_pos) catch break;
            if (is_64bit) _ = readU64(debug_info, &temp_pos) catch break;
            _ = readU16(debug_info, &temp_pos) catch break;
            if (version >= 5) {
                temp_pos += 1; // unit_type
                temp_pos += 1; // address_size
                const abbrev_off = if (is_64bit) readU64(debug_info, &temp_pos) catch break else readU32(debug_info, &temp_pos) catch break;
                break :blk @as(usize, @intCast(abbrev_off));
            } else {
                const abbrev_off = if (is_64bit) readU64(debug_info, &temp_pos) catch break else readU32(debug_info, &temp_pos) catch break;
                break :blk @as(usize, @intCast(abbrev_off));
            }
        };

        // Parse abbreviation table for this CU
        const abbrevs = parseAbbrevTable(debug_abbrev[abbrev_offset_for_cu..], allocator) catch {
            cu_pos = unit_end;
            continue;
        };
        defer allocator.free(abbrevs);

        // Read root DIE abbreviation code
        if (cu_pos >= unit_end) {
            cu_pos = unit_end;
            continue;
        }
        const root_abbrev_code = readULEB128(debug_info, &cu_pos) catch {
            cu_pos = unit_end;
            continue;
        };
        if (root_abbrev_code == 0) {
            cu_pos = unit_end;
            continue;
        }

        const root_abbrev = findAbbrev(abbrevs, root_abbrev_code);
        if (root_abbrev == null) {
            cu_pos = unit_end;
            continue;
        }

        // Scan attributes for DW_AT_dwo_name/DW_AT_GNU_dwo_name and DW_AT_comp_dir
        var dwo_name: ?[]const u8 = null;
        var comp_dir: []const u8 = "";
        var dwo_id: u64 = 0;
        var has_dwo_id = false;
        const str_offsets_data = extra.debug_str_offsets;
        _ = str_offsets_data;

        for (root_abbrev.?.attributes) |attr| {
            if (attr.form == DW_FORM_implicit_const) continue;

            switch (attr.name) {
                DW_AT_dwo_name, DW_AT_GNU_dwo_name => {
                    if (attr.form == DW_FORM_string) {
                        dwo_name = readNullTermString(debug_info, &cu_pos);
                    } else if (attr.form == DW_FORM_strp) {
                        const str_offset = if (is_64bit)
                            readU64(debug_info, &cu_pos) catch break
                        else
                            readU32(debug_info, &cu_pos) catch break;
                        if (debug_str) |s| dwo_name = readStringAt(s, @intCast(str_offset));
                    } else {
                        skipForm(debug_info, &cu_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_comp_dir => {
                    if (attr.form == DW_FORM_string) {
                        comp_dir = readNullTermString(debug_info, &cu_pos);
                    } else if (attr.form == DW_FORM_strp) {
                        const str_offset = if (is_64bit)
                            readU64(debug_info, &cu_pos) catch break
                        else
                            readU32(debug_info, &cu_pos) catch break;
                        if (debug_str) |s| comp_dir = readStringAt(s, @intCast(str_offset)) orelse "";
                    } else {
                        skipForm(debug_info, &cu_pos, attr.form, is_64bit) catch break;
                    }
                },
                DW_AT_dwo_id, DW_AT_GNU_dwo_id => {
                    if (attr.form == DW_FORM_data8) {
                        dwo_id = readU64(debug_info, &cu_pos) catch break;
                        has_dwo_id = true;
                    } else {
                        skipForm(debug_info, &cu_pos, attr.form, is_64bit) catch break;
                    }
                },
                else => {
                    skipForm(debug_info, &cu_pos, attr.form, is_64bit) catch break;
                },
            }
        }

        if (dwo_name) |dn| {
            try skeletons.append(allocator, .{
                .dwo_name = dn,
                .comp_dir = comp_dir,
                .dwo_id = dwo_id,
                .has_dwo_id = has_dwo_id,
            });
        }

        cu_pos = unit_end;
    }

    return try skeletons.toOwnedSlice(allocator);
}

// ── .debug_macro Parsing (DWARF5 Section 6.3) ──────────────────────────

/// A parsed macro definition from .debug_macro.
pub const MacroDef = struct {
    name: []const u8,
    definition: []const u8,
    line: u32,
    file_index: u32 = 0,
    is_undef: bool = false,
};

// DWARF5 macro opcodes
const DW_MACRO_define: u8 = 0x01;
const DW_MACRO_undef: u8 = 0x02;
const DW_MACRO_start_file: u8 = 0x03;
const DW_MACRO_end_file: u8 = 0x04;
const DW_MACRO_define_strp: u8 = 0x05;
const DW_MACRO_undef_strp: u8 = 0x06;
const DW_MACRO_import: u8 = 0x07;
const DW_MACRO_define_strx: u8 = 0x0b;
const DW_MACRO_undef_strx: u8 = 0x0c;

/// Parse the .debug_macro section and return all macro definitions.
pub fn parseDebugMacro(
    data: []const u8,
    debug_str: ?[]const u8,
    debug_str_offsets: ?[]const u8,
    str_offsets_base: u64,
    is_64bit: bool,
    allocator: std.mem.Allocator,
) ![]MacroDef {
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();
    return parseDebugMacroImpl(data, debug_str, debug_str_offsets, str_offsets_base, is_64bit, allocator, 0, &visited, 0);
}

fn parseDebugMacroImpl(
    data: []const u8,
    debug_str: ?[]const u8,
    debug_str_offsets: ?[]const u8,
    str_offsets_base: u64,
    is_64bit: bool,
    allocator: std.mem.Allocator,
    start_offset: usize,
    visited: *std.AutoHashMap(u64, void),
    depth: u32,
) ![]MacroDef {
    // Prevent infinite recursion
    if (depth > 32) return &.{};
    if (visited.contains(@intCast(start_offset))) return &.{};
    try visited.put(@intCast(start_offset), {});
    if (data.len < 4) return &.{};

    var pos: usize = start_offset;

    // Header: version (2 bytes), flags (1 byte)
    const version = readU16(data, &pos) catch return &.{};
    if (version != 5 and version != 4) return &.{};

    const flags = if (pos < data.len) data[pos] else return &.{};
    pos += 1;

    // Flags: bit 0 = offset_size_flag, bit 1 = debug_line_offset_flag, bit 2 = opcode_operands_table_flag
    const offset_size_flag = (flags & 0x01) != 0;
    const debug_line_offset_flag = (flags & 0x02) != 0;
    const opcode_operands_table_flag = (flags & 0x04) != 0;
    _ = offset_size_flag;

    // Skip .debug_line offset if present
    if (debug_line_offset_flag) {
        if (is_64bit) {
            _ = readU64(data, &pos) catch return &.{};
        } else {
            _ = readU32(data, &pos) catch return &.{};
        }
    }

    // Skip vendor opcode operands table if present
    if (opcode_operands_table_flag) {
        const table_count = if (pos < data.len) data[pos] else return &.{};
        pos += 1;
        for (0..table_count) |_| {
            // opcode (1 byte)
            pos += 1;
            // operand count (ULEB128)
            const op_count = readULEB128(data, &pos) catch break;
            // Skip operand forms
            for (0..op_count) |_| {
                _ = readULEB128(data, &pos) catch break;
            }
        }
    }

    var macros = std.ArrayListUnmanaged(MacroDef).empty;
    errdefer macros.deinit(allocator);

    var current_file: u32 = 0;

    while (pos < data.len) {
        const opcode = data[pos];
        pos += 1;
        if (opcode == 0) break; // End of list

        switch (opcode) {
            DW_MACRO_define => {
                const line = @as(u32, @intCast(readULEB128(data, &pos) catch break));
                const macro_str = readNullTermString(data, &pos);
                const split = splitMacroDef(macro_str);
                try macros.append(allocator, .{
                    .name = split.name,
                    .definition = split.body,
                    .line = line,
                    .file_index = current_file,
                });
            },
            DW_MACRO_undef => {
                const line = @as(u32, @intCast(readULEB128(data, &pos) catch break));
                const macro_str = readNullTermString(data, &pos);
                try macros.append(allocator, .{
                    .name = macro_str,
                    .definition = "",
                    .line = line,
                    .file_index = current_file,
                    .is_undef = true,
                });
            },
            DW_MACRO_define_strp => {
                const line = @as(u32, @intCast(readULEB128(data, &pos) catch break));
                const str_offset = if (is_64bit)
                    readU64(data, &pos) catch break
                else
                    readU32(data, &pos) catch break;
                const macro_str = if (debug_str) |s| readStringAt(s, @intCast(str_offset)) orelse "" else "";
                const split = splitMacroDef(macro_str);
                try macros.append(allocator, .{
                    .name = split.name,
                    .definition = split.body,
                    .line = line,
                    .file_index = current_file,
                });
            },
            DW_MACRO_undef_strp => {
                const line = @as(u32, @intCast(readULEB128(data, &pos) catch break));
                const str_offset = if (is_64bit)
                    readU64(data, &pos) catch break
                else
                    readU32(data, &pos) catch break;
                const macro_str = if (debug_str) |s| readStringAt(s, @intCast(str_offset)) orelse "" else "";
                try macros.append(allocator, .{
                    .name = macro_str,
                    .definition = "",
                    .line = line,
                    .file_index = current_file,
                    .is_undef = true,
                });
            },
            DW_MACRO_define_strx => {
                const line = @as(u32, @intCast(readULEB128(data, &pos) catch break));
                const index = readULEB128(data, &pos) catch break;
                const macro_str = resolveStrx(debug_str, debug_str_offsets, str_offsets_base, index, is_64bit) orelse "";
                const split = splitMacroDef(macro_str);
                try macros.append(allocator, .{
                    .name = split.name,
                    .definition = split.body,
                    .line = line,
                    .file_index = current_file,
                });
            },
            DW_MACRO_undef_strx => {
                const line = @as(u32, @intCast(readULEB128(data, &pos) catch break));
                const index = readULEB128(data, &pos) catch break;
                const macro_str = resolveStrx(debug_str, debug_str_offsets, str_offsets_base, index, is_64bit) orelse "";
                try macros.append(allocator, .{
                    .name = macro_str,
                    .definition = "",
                    .line = line,
                    .file_index = current_file,
                    .is_undef = true,
                });
            },
            DW_MACRO_start_file => {
                _ = readULEB128(data, &pos) catch break; // line
                const file_idx = readULEB128(data, &pos) catch break;
                current_file = @intCast(file_idx);
            },
            DW_MACRO_end_file => {
                current_file = 0;
            },
            DW_MACRO_import => {
                const import_offset = if (is_64bit)
                    readU64(data, &pos) catch break
                else
                    @as(u64, readU32(data, &pos) catch break);
                const imported = parseDebugMacroImpl(
                    data,
                    debug_str,
                    debug_str_offsets,
                    str_offsets_base,
                    is_64bit,
                    allocator,
                    @intCast(import_offset),
                    visited,
                    depth + 1,
                ) catch &.{};
                defer if (imported.len > 0) allocator.free(imported);
                for (imported) |m| {
                    try macros.append(allocator, m);
                }
            },
            else => break, // Unknown opcode, stop parsing
        }
    }

    return try macros.toOwnedSlice(allocator);
}

/// Split a macro definition string "NAME body" into name and body parts.
fn splitMacroDef(s: []const u8) struct { name: []const u8, body: []const u8 } {
    // Find first space or '(' for function-like macros
    for (s, 0..) |c, i| {
        if (c == ' ' or c == '\t') {
            return .{
                .name = s[0..i],
                .body = if (i + 1 < s.len) s[i + 1 ..] else "",
            };
        }
        if (c == '(') {
            // Function-like macro: NAME(args) body — include args in name
            var j = i;
            while (j < s.len and s[j] != ')') j += 1;
            if (j < s.len) j += 1; // skip ')'
            // Skip space after closing paren
            if (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
            return .{
                .name = s[0..i],
                .body = if (j < s.len) s[j..] else "",
            };
        }
    }
    return .{ .name = s, .body = "" };
}

// ── Tests ───────────────────────────────────────────────────────────────

test "readULEB128 decodes single byte" {
    const data = [_]u8{0x42};
    var pos: usize = 0;
    const result = try readULEB128(&data, &pos);
    try std.testing.expectEqual(@as(u64, 0x42), result);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readULEB128 decodes multi-byte" {
    // 624485 = 0x98765 = 0b10011000011101100101
    // LEB128: 0xE5, 0x8E, 0x26
    const data = [_]u8{ 0xE5, 0x8E, 0x26 };
    var pos: usize = 0;
    const result = try readULEB128(&data, &pos);
    try std.testing.expectEqual(@as(u64, 624485), result);
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "readULEB128 decodes zero" {
    const data = [_]u8{0x00};
    var pos: usize = 0;
    const result = try readULEB128(&data, &pos);
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "readULEB128 returns error on empty data" {
    const data = [_]u8{};
    var pos: usize = 0;
    try std.testing.expectError(error.UnexpectedEndOfData, readULEB128(&data, &pos));
}

test "readSLEB128 decodes positive value" {
    // 42 = 0x2A = 0b00101010, bit 6 is clear so it's positive in SLEB128
    const data = [_]u8{0x2A};
    var pos: usize = 0;
    const result = try readSLEB128(&data, &pos);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "readSLEB128 decodes negative value" {
    // -123456 in SLEB128: 0xC0, 0xBB, 0x78
    const data = [_]u8{ 0xC0, 0xBB, 0x78 };
    var pos: usize = 0;
    const result = try readSLEB128(&data, &pos);
    try std.testing.expectEqual(@as(i64, -123456), result);
}

test "readSLEB128 decodes minus one" {
    const data = [_]u8{0x7f};
    var pos: usize = 0;
    const result = try readSLEB128(&data, &pos);
    try std.testing.expectEqual(@as(i64, -1), result);
}

test "parseAbbrevTable parses abbreviation declarations" {
    // Construct a minimal abbreviation table:
    // Entry 1: code=1, tag=DW_TAG_compile_unit (0x11), has_children=yes
    //   attr: DW_AT_name (0x03), DW_FORM_string (0x08)
    //   end: 0, 0
    // End: 0
    const data = [_]u8{
        0x01,       // code = 1
        0x11,       // tag = DW_TAG_compile_unit
        0x01,       // has_children = yes
        0x03, 0x08, // DW_AT_name, DW_FORM_string
        0x00, 0x00, // end of attributes
        0x00, // end of table
    };

    const entries = try parseAbbrevTable(&data, std.testing.allocator);
    defer freeAbbrevTable(entries, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u64, 1), entries[0].code);
    try std.testing.expectEqual(DW_TAG_compile_unit, entries[0].tag);
    try std.testing.expect(entries[0].has_children);
    try std.testing.expectEqual(@as(usize, 1), entries[0].attributes.len);
    try std.testing.expectEqual(DW_AT_name, entries[0].attributes[0].name);
    try std.testing.expectEqual(DW_FORM_string, entries[0].attributes[0].form);
}

test "parseAbbrevTable parses multiple entries" {
    const data = [_]u8{
        // Entry 1: compile_unit
        0x01,       0x11, 0x01,
        0x03,       0x08, // AT_name, FORM_string
        0x00,       0x00,
        // Entry 2: subprogram
        0x02,       0x2e, 0x00, // no children
        0x03,       0x08, // AT_name, FORM_string
        0x11,       0x01, // AT_low_pc, FORM_addr
        0x00,       0x00,
        // End
        0x00,
    };

    const entries = try parseAbbrevTable(&data, std.testing.allocator);
    defer freeAbbrevTable(entries, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(DW_TAG_compile_unit, entries[0].tag);
    try std.testing.expectEqual(DW_TAG_subprogram, entries[1].tag);
    try std.testing.expect(!entries[1].has_children);
    try std.testing.expectEqual(@as(usize, 2), entries[1].attributes.len);
}

test "resolveAddress returns null for empty entries" {
    const entries = [_]LineEntry{};
    const files = [_]FileEntry{};
    const result = resolveAddress(&entries, &files, 0x1000);
    try std.testing.expect(result == null);
}

test "resolveAddress returns null for unknown address" {
    const entries = [_]LineEntry{
        .{ .address = 0x2000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };
    const files = [_]FileEntry{
        .{ .name = "test.c", .dir_index = 0 },
    };
    // Address before any entry
    const result = resolveAddress(&entries, &files, 0x1000);
    try std.testing.expect(result == null);
}

test "resolveAddress returns source location for known address" {
    const entries = [_]LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 3, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1010, .file_index = 1, .line = 6, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 7, .column = 0, .is_stmt = true, .end_sequence = true },
    };
    const files = [_]FileEntry{
        .{ .name = "test.c", .dir_index = 0 },
    };
    const result = resolveAddress(&entries, &files, 0x1008);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test.c", result.?.file);
    try std.testing.expectEqual(@as(u32, 5), result.?.line);
}

test "resolveAddress maps address between entries" {
    const entries = [_]LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 15, .column = 0, .is_stmt = true, .end_sequence = false },
    };
    const files = [_]FileEntry{
        .{ .name = "main.c", .dir_index = 0 },
    };
    // Address between two entries should map to the earlier entry
    const result = resolveAddress(&entries, &files, 0x1010);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 10), result.?.line);
}

test "resolveFunction returns address range for known function" {
    const functions = [_]FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1050 },
        .{ .name = "add", .low_pc = 0x1050, .high_pc = 0x1080 },
    };
    const result = resolveFunction(&functions, "add");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 0x1050), result.?.low_pc);
    try std.testing.expectEqual(@as(u64, 0x1080), result.?.high_pc);
}

test "resolveFunction returns null for unknown function" {
    const functions = [_]FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1050 },
    };
    const result = resolveFunction(&functions, "nonexistent");
    try std.testing.expect(result == null);
}

test "parseLineProgram parses fixture debug_line section" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const macho = binary_macho.MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer {
        var m = macho;
        m.deinit(std.testing.allocator);
    }

    const line_info = macho.sections.debug_line orelse return error.SkipZigTest;
    const line_data = macho.getSectionData(line_info) orelse return error.SkipZigTest;

    const entries = try parseLineProgram(line_data, std.testing.allocator);
    defer std.testing.allocator.free(entries);

    // Should have at least some line entries
    try std.testing.expect(entries.len > 0);

    // At least one entry should have line > 0
    var has_valid_line = false;
    for (entries) |entry| {
        if (entry.line > 0 and !entry.end_sequence) {
            has_valid_line = true;
            break;
        }
    }
    try std.testing.expect(has_valid_line);
}

test "parseCompilationUnit extracts function names from fixture" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const macho = binary_macho.MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer {
        var m = macho;
        m.deinit(std.testing.allocator);
    }

    const info_section = macho.sections.debug_info orelse return error.SkipZigTest;
    const abbrev_section = macho.sections.debug_abbrev orelse return error.SkipZigTest;

    const info_data = macho.getSectionData(info_section) orelse return error.SkipZigTest;
    const abbrev_data = macho.getSectionData(abbrev_section) orelse return error.SkipZigTest;
    const str_data = if (macho.sections.debug_str) |s| macho.getSectionData(s) else null;
    const str_offsets_data = if (macho.sections.debug_str_offsets) |s| macho.getSectionData(s) else null;
    const addr_data = if (macho.sections.debug_addr) |s| macho.getSectionData(s) else null;

    const functions = try parseCompilationUnitEx(
        info_data,
        abbrev_data,
        str_data,
        .{ .debug_str_offsets = str_offsets_data, .debug_addr = addr_data },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(functions);

    // The fixture has 'add' and 'main' functions
    var found_add = false;
    var found_main = false;
    for (functions) |f| {
        if (std.mem.eql(u8, f.name, "add")) found_add = true;
        if (std.mem.eql(u8, f.name, "main")) found_main = true;
    }

    // At least one function should be found
    try std.testing.expect(found_add or found_main);
}

test "parseCompilationUnit extracts variable declarations" {
    // Construct a minimal DWARF .debug_info with a variable DIE.
    // CU header: length=33, version=4, abbrev_offset=0, addr_size=8
    // DIE 1 (abbrev 1): DW_TAG_compile_unit, DW_AT_name="test.c"
    // DIE 2 (abbrev 2): DW_TAG_base_type, DW_AT_name="int", DW_AT_encoding=5, DW_AT_byte_size=4
    // DIE 3 (abbrev 3): DW_TAG_variable, DW_AT_name="x", DW_AT_type=ref4(offset of base_type)
    //
    // Abbreviation table:
    // 1: DW_TAG_compile_unit, has_children, AT_name(FORM_string), 0,0
    // 2: DW_TAG_base_type, no_children, AT_name(FORM_string), AT_encoding(FORM_data1), AT_byte_size(FORM_data1), 0,0
    // 3: DW_TAG_variable, no_children, AT_name(FORM_string), AT_type(FORM_ref4), 0,0
    // 0: end

    const abbrev_data = [_]u8{
        // Abbrev 1: compile_unit
        0x01, 0x11, 0x01, // code=1, tag=compile_unit, has_children=yes
        0x03, 0x08, // AT_name, FORM_string
        0x00, 0x00,
        // Abbrev 2: base_type
        0x02, 0x24, 0x00, // code=2, tag=base_type, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x3e, 0x0b, // AT_encoding, FORM_data1
        0x0b, 0x0b, // AT_byte_size, FORM_data1
        0x00, 0x00,
        // Abbrev 3: variable
        0x03, 0x34, 0x00, // code=3, tag=variable, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x49, 0x13, // AT_type, FORM_ref4
        0x00, 0x00,
        // End
        0x00,
    };

    // Build debug_info:
    // CU header: 4-byte length (to be filled), version=4, abbrev_offset=0, addr_size=8
    // Then DIEs
    var info_buf: [128]u8 = undefined;
    var ipos: usize = 0;

    // Leave space for length (4 bytes)
    ipos += 4;

    // Version = 4
    std.mem.writeInt(u16, info_buf[ipos..][0..2], 4, .little);
    ipos += 2;

    // Abbrev offset = 0
    std.mem.writeInt(u32, info_buf[ipos..][0..4], 0, .little);
    ipos += 4;

    // Address size = 8
    info_buf[ipos] = 8;
    ipos += 1;

    // DIE 1: compile_unit, AT_name="test.c\0"
    info_buf[ipos] = 0x01; // abbrev code 1
    ipos += 1;
    const cu_name = "test.c";
    @memcpy(info_buf[ipos..][0..cu_name.len], cu_name);
    ipos += cu_name.len;
    info_buf[ipos] = 0; // null terminator
    ipos += 1;

    // DIE 2: base_type at offset (ipos - 4) relative to CU start
    const base_type_offset = ipos - 4; // offset from start of CU header data
    info_buf[ipos] = 0x02; // abbrev code 2
    ipos += 1;
    const type_name = "int";
    @memcpy(info_buf[ipos..][0..type_name.len], type_name);
    ipos += type_name.len;
    info_buf[ipos] = 0;
    ipos += 1;
    info_buf[ipos] = 0x05; // DW_ATE_signed
    ipos += 1;
    info_buf[ipos] = 0x04; // 4 bytes
    ipos += 1;

    // DIE 3: variable
    info_buf[ipos] = 0x03; // abbrev code 3
    ipos += 1;
    const var_name = "x";
    @memcpy(info_buf[ipos..][0..var_name.len], var_name);
    ipos += var_name.len;
    info_buf[ipos] = 0;
    ipos += 1;
    // AT_type: ref4 pointing to base_type_offset
    std.mem.writeInt(u32, info_buf[ipos..][0..4], @intCast(base_type_offset), .little);
    ipos += 4;

    // Null DIE (end of children)
    info_buf[ipos] = 0x00;
    ipos += 1;

    // Fill in CU length (total - 4 bytes for the length field itself)
    const cu_len: u32 = @intCast(ipos - 4);
    std.mem.writeInt(u32, info_buf[0..4], cu_len, .little);

    const vars = try parseVariables(info_buf[0..ipos], &abbrev_data, null, std.testing.allocator);
    defer freeVariables(vars, std.testing.allocator);

    try std.testing.expect(vars.len >= 1);

    var found_x = false;
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, "x")) {
            found_x = true;
            try std.testing.expectEqual(@as(u8, 0x05), v.type_encoding); // DW_ATE_signed
            try std.testing.expectEqual(@as(u8, 4), v.type_byte_size);
        }
    }
    try std.testing.expect(found_x);
}

test "skipForm handles DW_FORM_indirect" {
    // DW_FORM_indirect: ULEB128 for actual form, then the form's data.
    // Here: actual form = DW_FORM_data2 (0x05), followed by 2 bytes of data.
    const data = [_]u8{ 0x05, 0xAA, 0xBB };
    var pos: usize = 0;
    try skipForm(&data, &pos, DW_FORM_indirect, false);
    // Should have consumed 1 byte (ULEB128 for form) + 2 bytes (data2) = 3
    try std.testing.expectEqual(@as(usize, 3), pos);
}

test "skipForm handles DW_FORM_indirect with ULEB128 form" {
    // DW_FORM_indirect pointing to DW_FORM_udata (0x0f), then a ULEB128 value
    const data = [_]u8{ 0x0f, 0x42 };
    var pos: usize = 0;
    try skipForm(&data, &pos, DW_FORM_indirect, false);
    // 1 byte (ULEB128 for form=0x0f) + 1 byte (ULEB128 value 0x42) = 2
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "pcInRangeListDwarf5Full resolves DW_RLE_base_addressx" {
    // Build a .debug_addr section with a single address entry at offset 0
    var debug_addr: [8]u8 = undefined;
    std.mem.writeInt(u64, debug_addr[0..8], 0x1000, .little);

    // Build an rnglists section:
    // DW_RLE_base_addressx (0x01), index=0 (ULEB128)
    // DW_RLE_offset_pair (0x04), begin=0 (ULEB128), end=0x50 (ULEB128)
    // DW_RLE_end_of_list (0x00)
    const rnglists2 = [_]u8{
        0x01, 0x00, // base_addressx, index=0
        0x04, 0x00, 0x50, // offset_pair, begin=0, end=0x50
        0x00, // end_of_list
    };

    // PC 0x1020 should be in range [0x1000, 0x1050)
    const result = pcInRangeListDwarf5Full(&rnglists2, 0, 0x1020, 0, &debug_addr, 0, 8);
    try std.testing.expect(result);

    // PC 0x1060 should NOT be in range
    const result2 = pcInRangeListDwarf5Full(&rnglists2, 0, 0x1060, 0, &debug_addr, 0, 8);
    try std.testing.expect(!result2);
}

test "pcInRangeListDwarf5Full resolves DW_RLE_startx_length" {
    // .debug_addr with one entry at offset 0: address 0x2000
    var debug_addr: [8]u8 = undefined;
    std.mem.writeInt(u64, debug_addr[0..8], 0x2000, .little);

    // rnglists: DW_RLE_startx_length, index=0, length=0x40, then end_of_list
    const rnglists = [_]u8{
        0x03, 0x00, 0x40, // startx_length, index=0, length=0x40
        0x00, // end_of_list
    };

    // PC 0x2010 in [0x2000, 0x2040)
    try std.testing.expect(pcInRangeListDwarf5Full(&rnglists, 0, 0x2010, 0, &debug_addr, 0, 8));
    // PC 0x2050 NOT in range
    try std.testing.expect(!pcInRangeListDwarf5Full(&rnglists, 0, 0x2050, 0, &debug_addr, 0, 8));
}

test "pcInRangeListDwarf5Full resolves DW_RLE_startx_endx" {
    // .debug_addr with two entries at offset 0: start=0x3000, end=0x3080
    var debug_addr: [16]u8 = undefined;
    std.mem.writeInt(u64, debug_addr[0..8], 0x3000, .little);
    std.mem.writeInt(u64, debug_addr[8..16], 0x3080, .little);

    // rnglists: DW_RLE_startx_endx, start_idx=0, end_idx=1, then end_of_list
    const rnglists = [_]u8{
        0x02, 0x00, 0x01, // startx_endx, start_idx=0, end_idx=1
        0x00, // end_of_list
    };

    // PC 0x3040 in [0x3000, 0x3080)
    try std.testing.expect(pcInRangeListDwarf5Full(&rnglists, 0, 0x3040, 0, &debug_addr, 0, 8));
    // PC 0x3080 NOT in range (half-open interval)
    try std.testing.expect(!pcInRangeListDwarf5Full(&rnglists, 0, 0x3080, 0, &debug_addr, 0, 8));
}

test "collectTypeDies collects class_type and union_type" {
    // Abbreviation table with class_type and union_type
    const abbrev_data = [_]u8{
        // Abbrev 1: compile_unit
        0x01, 0x11, 0x01, // code=1, tag=compile_unit, has_children=yes
        0x03, 0x08, // AT_name, FORM_string
        0x00, 0x00,
        // Abbrev 2: class_type (0x02)
        0x02, 0x02, 0x00, // code=2, tag=class_type, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x0b, 0x0b, // AT_byte_size, FORM_data1
        0x00, 0x00,
        // Abbrev 3: union_type (0x17)
        0x03, 0x17, 0x00, // code=3, tag=union_type, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x0b, 0x0b, // AT_byte_size, FORM_data1
        0x00, 0x00,
        // End
        0x00,
    };

    // Build debug_info
    var info_buf: [128]u8 = undefined;
    var ipos: usize = 0;

    // CU header (DWARF 4)
    ipos += 4; // length placeholder
    std.mem.writeInt(u16, info_buf[ipos..][0..2], 4, .little);
    ipos += 2;
    std.mem.writeInt(u32, info_buf[ipos..][0..4], 0, .little);
    ipos += 4;
    info_buf[ipos] = 8; // address_size
    ipos += 1;

    // DIE 1: compile_unit, name="test\0"
    info_buf[ipos] = 0x01;
    ipos += 1;
    @memcpy(info_buf[ipos..][0..5], "test\x00");
    ipos += 5;

    // DIE 2: class_type, name="MyClass\0", byte_size=16
    const class_offset = ipos;
    info_buf[ipos] = 0x02;
    ipos += 1;
    @memcpy(info_buf[ipos..][0..8], "MyClass\x00");
    ipos += 8;
    info_buf[ipos] = 16;
    ipos += 1;

    // DIE 3: union_type, name="MyUnion\0", byte_size=8
    const union_offset = ipos;
    info_buf[ipos] = 0x03;
    ipos += 1;
    @memcpy(info_buf[ipos..][0..8], "MyUnion\x00");
    ipos += 8;
    info_buf[ipos] = 8;
    ipos += 1;

    // Null DIE
    info_buf[ipos] = 0x00;
    ipos += 1;

    // Fill CU length
    const cu_len: u32 = @intCast(ipos - 4);
    std.mem.writeInt(u32, info_buf[0..4], cu_len, .little);

    const abbrevs = try parseAbbrevTable(&abbrev_data, std.testing.allocator);
    defer freeAbbrevTable(abbrevs, std.testing.allocator);

    // collectTypeDies starts after CU header (offset 11 for DWARF 4, 32-bit)
    var type_map = try collectTypeDies(
        info_buf[0..ipos],
        abbrevs,
        null,
        .{},
        0,
        false,
        8,
        11, // start after CU header
        ipos,
        std.testing.allocator,
    );
    defer type_map.deinit();

    // Verify class_type was collected
    const class_die = type_map.get(class_offset);
    try std.testing.expect(class_die != null);
    try std.testing.expectEqual(DW_TAG_class_type, class_die.?.tag);
    try std.testing.expectEqualStrings("MyClass", class_die.?.name orelse "");

    // Verify union_type was collected
    const union_die = type_map.get(union_offset);
    try std.testing.expect(union_die != null);
    try std.testing.expectEqual(DW_TAG_union_type, union_die.?.tag);
    try std.testing.expectEqualStrings("MyUnion", union_die.?.name orelse "");
}

test "resolveTypeDescription handles class_type as structure" {
    // Build a minimal type map with a class_type entry
    var type_map = std.AutoHashMap(u64, TypeDie).init(std.testing.allocator);
    defer type_map.deinit();

    try type_map.put(100, TypeDie{
        .tag = DW_TAG_class_type,
        .name = "MyClass",
        .byte_size = 16,
    });

    const desc = try resolveTypeDescription(&type_map, 100, std.testing.allocator);
    defer freeTypeDescription(desc, std.testing.allocator);

    try std.testing.expectEqual(TypeKind.structure, desc.kind);
    try std.testing.expectEqualStrings("MyClass", desc.name);
    try std.testing.expectEqual(@as(u8, 16), desc.byte_size);
}

test "resolveTypeDescription handles reference_type as pointer" {
    var type_map = std.AutoHashMap(u64, TypeDie).init(std.testing.allocator);
    defer type_map.deinit();

    // Base type
    try type_map.put(50, TypeDie{
        .tag = DW_TAG_base_type,
        .name = "int",
        .encoding = 0x05,
        .byte_size = 4,
    });

    // Reference type pointing to int
    try type_map.put(100, TypeDie{
        .tag = DW_TAG_reference_type,
        .byte_size = 8,
        .has_type_ref = true,
        .type_ref = 50,
    });

    const desc = try resolveTypeDescription(&type_map, 100, std.testing.allocator);
    try std.testing.expectEqual(TypeKind.pointer, desc.kind);
    try std.testing.expectEqualStrings("int", desc.pointee_name);
}

test "resolveTypeDescription handles subroutine_type as function pointer" {
    var type_map = std.AutoHashMap(u64, TypeDie).init(std.testing.allocator);
    defer type_map.deinit();

    // Return type
    try type_map.put(50, TypeDie{
        .tag = DW_TAG_base_type,
        .name = "void",
        .byte_size = 0,
    });

    // Subroutine type with return type
    try type_map.put(100, TypeDie{
        .tag = DW_TAG_subroutine_type,
        .has_type_ref = true,
        .type_ref = 50,
    });

    const desc = try resolveTypeDescription(&type_map, 100, std.testing.allocator);
    try std.testing.expectEqual(TypeKind.pointer, desc.kind);
    try std.testing.expectEqual(@as(u8, 8), desc.byte_size);
    try std.testing.expectEqualStrings("void", desc.pointee_name);
}

test "resolveTypeDescription handles atomic_type as qualifier" {
    var type_map = std.AutoHashMap(u64, TypeDie).init(std.testing.allocator);
    defer type_map.deinit();

    // Base type
    try type_map.put(50, TypeDie{
        .tag = DW_TAG_base_type,
        .name = "int",
        .encoding = 0x05,
        .byte_size = 4,
    });

    // Atomic qualifier
    try type_map.put(100, TypeDie{
        .tag = DW_TAG_atomic_type,
        .has_type_ref = true,
        .type_ref = 50,
    });

    const desc = try resolveTypeDescription(&type_map, 100, std.testing.allocator);
    try std.testing.expectEqual(TypeKind.const_type, desc.kind);
    try std.testing.expectEqualStrings("int", desc.name);
}

test "parseInlinedSubroutines extracts inlined subroutine info from synthetic DWARF" {
    // Build a synthetic DWARF .debug_info with:
    // - CU header (DWARF 4)
    // - DIE 1 (abbrev 1): DW_TAG_compile_unit, has_children
    // - DIE 2 (abbrev 2): DW_TAG_subprogram, name="caller", low_pc=0x1000, high_pc=0x1100
    // - DIE 3 (abbrev 3): DW_TAG_inlined_subroutine, abstract_origin=ref4(offset of subprogram DIE),
    //                       call_file=1, call_line=42, call_column=5,
    //                       low_pc=0x1020, high_pc=0x1050
    //
    // Abbreviation table:
    // 1: DW_TAG_compile_unit(0x11), has_children, AT_name(FORM_string), 0,0
    // 2: DW_TAG_subprogram(0x2e), no_children, AT_name(FORM_string), AT_low_pc(FORM_addr), AT_high_pc(FORM_addr), 0,0
    // 3: DW_TAG_inlined_subroutine(0x1d), no_children,
    //    AT_abstract_origin(FORM_ref4), AT_call_file(FORM_data1), AT_call_line(FORM_data1),
    //    AT_call_column(FORM_data1), AT_low_pc(FORM_addr), AT_high_pc(FORM_addr), 0,0
    // 0: end

    const abbrev_data = [_]u8{
        // Abbrev 1: compile_unit
        0x01, 0x11, 0x01, // code=1, tag=compile_unit, has_children=yes
        0x03, 0x08, // AT_name, FORM_string
        0x00, 0x00,
        // Abbrev 2: subprogram
        0x02, 0x2e, 0x00, // code=2, tag=subprogram, no_children
        0x03, 0x08, // AT_name, FORM_string
        0x11, 0x01, // AT_low_pc, FORM_addr
        0x12, 0x01, // AT_high_pc, FORM_addr
        0x00, 0x00,
        // Abbrev 3: inlined_subroutine
        0x03, 0x1d, 0x00, // code=3, tag=inlined_subroutine, no_children
        0x31, 0x13, // AT_abstract_origin, FORM_ref4
        0x58, 0x0b, // AT_call_file, FORM_data1
        0x59, 0x0b, // AT_call_line, FORM_data1
        0x57, 0x0b, // AT_call_column, FORM_data1
        0x11, 0x01, // AT_low_pc, FORM_addr
        0x12, 0x01, // AT_high_pc, FORM_addr
        0x00, 0x00,
        // End
        0x00,
    };

    // Build debug_info
    var info_buf: [256]u8 = undefined;
    var ipos: usize = 0;

    // CU header (DWARF 4): 4-byte length, version=4, abbrev_offset=0, addr_size=8
    ipos += 4; // length placeholder
    std.mem.writeInt(u16, info_buf[ipos..][0..2], 4, .little);
    ipos += 2;
    std.mem.writeInt(u32, info_buf[ipos..][0..4], 0, .little); // abbrev_offset
    ipos += 4;
    info_buf[ipos] = 8; // addr_size
    ipos += 1;

    // DIE 1: compile_unit (abbrev 1)
    info_buf[ipos] = 0x01; // abbrev code
    ipos += 1;
    // AT_name: "test.c\0"
    @memcpy(info_buf[ipos..][0..7], "test.c\x00");
    ipos += 7;

    // DIE 2: subprogram (abbrev 2) - record its offset for abstract_origin
    const subprogram_die_offset = ipos;
    info_buf[ipos] = 0x02; // abbrev code
    ipos += 1;
    // AT_name: "callee\0"
    @memcpy(info_buf[ipos..][0..7], "callee\x00");
    ipos += 7;
    // AT_low_pc: 0x1000 (8 bytes)
    std.mem.writeInt(u64, info_buf[ipos..][0..8], 0x1000, .little);
    ipos += 8;
    // AT_high_pc: 0x1100 (8 bytes)
    std.mem.writeInt(u64, info_buf[ipos..][0..8], 0x1100, .little);
    ipos += 8;

    // DIE 3: inlined_subroutine (abbrev 3)
    info_buf[ipos] = 0x03; // abbrev code
    ipos += 1;
    // AT_abstract_origin: ref4 pointing to the subprogram DIE offset
    std.mem.writeInt(u32, info_buf[ipos..][0..4], @intCast(subprogram_die_offset), .little);
    ipos += 4;
    // AT_call_file: 1
    info_buf[ipos] = 1;
    ipos += 1;
    // AT_call_line: 42
    info_buf[ipos] = 42;
    ipos += 1;
    // AT_call_column: 5
    info_buf[ipos] = 5;
    ipos += 1;
    // AT_low_pc: 0x1020
    std.mem.writeInt(u64, info_buf[ipos..][0..8], 0x1020, .little);
    ipos += 8;
    // AT_high_pc: 0x1050
    std.mem.writeInt(u64, info_buf[ipos..][0..8], 0x1050, .little);
    ipos += 8;

    // Null terminator for CU
    info_buf[ipos] = 0x00;
    ipos += 1;

    // Fill in the CU length (total content after the 4-byte length field)
    const cu_content_len: u32 = @intCast(ipos - 4);
    std.mem.writeInt(u32, info_buf[0..4], cu_content_len, .little);

    const debug_info = info_buf[0..ipos];
    const inlined = try parseInlinedSubroutines(debug_info, &abbrev_data, null, .{}, std.testing.allocator);
    defer std.testing.allocator.free(inlined);

    try std.testing.expectEqual(@as(usize, 1), inlined.len);
    try std.testing.expectEqual(@as(u32, 1), inlined[0].call_file);
    try std.testing.expectEqual(@as(u32, 42), inlined[0].call_line);
    try std.testing.expectEqual(@as(u32, 5), inlined[0].call_column);
    try std.testing.expectEqual(@as(u64, 0x1020), inlined[0].low_pc);
    try std.testing.expectEqual(@as(u64, 0x1050), inlined[0].high_pc);
    // Name should be resolved from abstract_origin
    try std.testing.expect(inlined[0].name != null);
    try std.testing.expectEqualStrings("callee", inlined[0].name.?);
}

test "findInlinedSubroutines detects PC within inlined range" {
    const subs = [_]InlinedSubroutineInfo{
        .{
            .abstract_origin = 100,
            .call_file = 1,
            .call_line = 10,
            .call_column = 3,
            .low_pc = 0x2000,
            .high_pc = 0x2080,
            .name = "inlined_func",
        },
        .{
            .abstract_origin = 200,
            .call_file = 1,
            .call_line = 20,
            .call_column = 1,
            .low_pc = 0x3000,
            .high_pc = 0x3040,
            .name = "other_func",
        },
    };

    // PC inside first inlined range
    const matches1 = try findInlinedSubroutines(&subs, 0x2040, std.testing.allocator);
    defer std.testing.allocator.free(matches1);
    try std.testing.expectEqual(@as(usize, 1), matches1.len);
    try std.testing.expectEqualStrings("inlined_func", matches1[0].name.?);

    // PC inside second inlined range
    const matches2 = try findInlinedSubroutines(&subs, 0x3020, std.testing.allocator);
    defer std.testing.allocator.free(matches2);
    try std.testing.expectEqual(@as(usize, 1), matches2.len);
    try std.testing.expectEqualStrings("other_func", matches2[0].name.?);

    // PC outside all ranges
    const matches3 = try findInlinedSubroutines(&subs, 0x4000, std.testing.allocator);
    defer std.testing.allocator.free(matches3);
    try std.testing.expectEqual(@as(usize, 0), matches3.len);

    // PC at boundary (low_pc is inclusive)
    const matches4 = try findInlinedSubroutines(&subs, 0x2000, std.testing.allocator);
    defer std.testing.allocator.free(matches4);
    try std.testing.expectEqual(@as(usize, 1), matches4.len);

    // PC at high_pc boundary (exclusive)
    const matches5 = try findInlinedSubroutines(&subs, 0x2080, std.testing.allocator);
    defer std.testing.allocator.free(matches5);
    try std.testing.expectEqual(@as(usize, 0), matches5.len);
}

test "findInlinedSubroutines handles empty input" {
    const empty: []const InlinedSubroutineInfo = &.{};
    const matches = try findInlinedSubroutines(empty, 0x1000, std.testing.allocator);
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}
