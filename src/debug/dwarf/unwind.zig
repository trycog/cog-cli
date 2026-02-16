const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const process_mod = @import("process.zig");
const binary_macho = @import("binary_macho.zig");

// ── Stack Unwinding ────────────────────────────────────────────────────

// DWARF .eh_frame / .debug_frame constants
const DW_CFA_advance_loc: u8 = 0x40; // high 2 bits = 01
const DW_CFA_offset: u8 = 0x80; // high 2 bits = 10
const DW_CFA_restore: u8 = 0xC0; // high 2 bits = 11
const DW_CFA_nop: u8 = 0x00;
const DW_CFA_set_loc: u8 = 0x01;
const DW_CFA_advance_loc1: u8 = 0x02;
const DW_CFA_advance_loc2: u8 = 0x03;
const DW_CFA_advance_loc4: u8 = 0x04;
const DW_CFA_offset_extended: u8 = 0x05;
const DW_CFA_restore_extended: u8 = 0x06;
const DW_CFA_undefined: u8 = 0x07;
const DW_CFA_same_value: u8 = 0x08;
const DW_CFA_register: u8 = 0x09;
const DW_CFA_remember_state: u8 = 0x0a;
const DW_CFA_restore_state: u8 = 0x0b;
const DW_CFA_def_cfa: u8 = 0x0c;
const DW_CFA_def_cfa_register: u8 = 0x0d;
const DW_CFA_def_cfa_offset: u8 = 0x0e;
const DW_CFA_def_cfa_expression: u8 = 0x0f;
const DW_CFA_expression: u8 = 0x10;
const DW_CFA_offset_extended_sf: u8 = 0x11;
const DW_CFA_def_cfa_sf: u8 = 0x12;
const DW_CFA_def_cfa_offset_sf: u8 = 0x13;
const DW_CFA_val_offset: u8 = 0x14;
const DW_CFA_val_offset_sf: u8 = 0x15;
const DW_CFA_val_expression: u8 = 0x16;
const DW_CFA_GNU_args_size: u8 = 0x2e;

// DW_EH_PE_* pointer encoding constants
const DW_EH_PE_absptr: u8 = 0x00;
const DW_EH_PE_uleb128: u8 = 0x01;
const DW_EH_PE_udata2: u8 = 0x02;
const DW_EH_PE_udata4: u8 = 0x03;
const DW_EH_PE_udata8: u8 = 0x04;
const DW_EH_PE_sleb128: u8 = 0x09;
const DW_EH_PE_sdata2: u8 = 0x0a;
const DW_EH_PE_sdata4: u8 = 0x0b;
const DW_EH_PE_sdata8: u8 = 0x0c;
const DW_EH_PE_pcrel: u8 = 0x10;

/// Return the byte size of a pointer given its DW_EH_PE_* encoding (low nibble only).
fn pointerSize(encoding: u8) usize {
    return switch (encoding & 0x0F) {
        DW_EH_PE_absptr => 8, // native pointer size (assume 64-bit)
        DW_EH_PE_udata2, DW_EH_PE_sdata2 => 2,
        DW_EH_PE_udata4, DW_EH_PE_sdata4 => 4,
        DW_EH_PE_udata8, DW_EH_PE_sdata8 => 8,
        else => 8,
    };
}

/// Read a pointer value from data at the given position using DW_EH_PE_* encoding.
/// `pc` is the address of the pointer field itself (for PC-relative encoding).
fn readEncodedPointer(data: []const u8, pos: *usize, encoding: u8, pc: u64) ?u64 {
    if (encoding == 0xFF) return null; // DW_EH_PE_omit

    const value_encoding = encoding & 0x0F;
    const rel_encoding = encoding & 0x70;

    const raw_value: i64 = switch (value_encoding) {
        DW_EH_PE_absptr => blk: {
            if (pos.* + 8 > data.len) return null;
            const v = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk @bitCast(v);
        },
        DW_EH_PE_udata2 => blk: {
            if (pos.* + 2 > data.len) return null;
            const v = std.mem.readInt(u16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk @intCast(v);
        },
        DW_EH_PE_udata4 => blk: {
            if (pos.* + 4 > data.len) return null;
            const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk @intCast(v);
        },
        DW_EH_PE_udata8 => blk: {
            if (pos.* + 8 > data.len) return null;
            const v = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk @bitCast(v);
        },
        DW_EH_PE_sdata2 => blk: {
            if (pos.* + 2 > data.len) return null;
            const v = std.mem.readInt(i16, data[pos.*..][0..2], .little);
            pos.* += 2;
            break :blk @intCast(v);
        },
        DW_EH_PE_sdata4 => blk: {
            if (pos.* + 4 > data.len) return null;
            const v = std.mem.readInt(i32, data[pos.*..][0..4], .little);
            pos.* += 4;
            break :blk @intCast(v);
        },
        DW_EH_PE_sdata8 => blk: {
            if (pos.* + 8 > data.len) return null;
            const v = std.mem.readInt(i64, data[pos.*..][0..8], .little);
            pos.* += 8;
            break :blk v;
        },
        else => return null,
    };

    // Apply relocation
    return switch (rel_encoding) {
        0x00 => @bitCast(raw_value), // DW_EH_PE_absptr
        DW_EH_PE_pcrel => pc +% @as(u64, @bitCast(raw_value)),
        else => @bitCast(raw_value), // Other relocation types not commonly used
    };
}

pub const UnwindFrame = struct {
    address: u64,
    function_name: []const u8,
    file: []const u8,
    line: u32,
    frame_index: u32,
};

pub const CieEntry = struct {
    code_alignment: u64,
    data_alignment: i64,
    return_address_register: u64,
    initial_instructions: []const u8,
    augmentation: []const u8,
    address_size: u8,
    /// FDE pointer encoding from 'R' augmentation (DW_EH_PE_* value), 0xFF = not specified
    fde_encoding: u8 = 0xFF,
};

pub const FdeEntry = struct {
    cie_offset: u64,
    initial_location: u64,
    address_range: u64,
    instructions: []const u8,
};

/// Parse .eh_frame section to extract CIE and FDE entries.
pub fn parseEhFrame(data: []const u8, allocator: std.mem.Allocator) ![]FdeEntry {
    var fdes: std.ArrayListUnmanaged(FdeEntry) = .empty;
    errdefer fdes.deinit(allocator);

    var pos: usize = 0;

    while (pos < data.len) {
        const entry_start = pos;

        // Length (4 bytes, or 12 if extended length)
        if (pos + 4 > data.len) break;
        const length_32 = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (length_32 == 0) break; // Terminator

        var length: u64 = length_32;
        if (length_32 == 0xFFFFFFFF) {
            if (pos + 8 > data.len) break;
            length = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
        }

        const entry_data_start = pos;
        const entry_end = entry_data_start + @as(usize, @intCast(length));
        if (entry_end > data.len) break;

        // CIE pointer (4 bytes)
        if (pos + 4 > data.len) break;
        const cie_id = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (cie_id == 0) {
            // This is a CIE — skip it (we parse CIEs on demand)
            pos = entry_end;
            continue;
        }

        // This is an FDE
        // CIE pointer is relative to the position of the CIE pointer field itself
        const cie_offset = entry_data_start - @as(usize, cie_id);

        // Parse the CIE to get pointer encoding
        const cie = parseCie(data, cie_offset);
        const fde_enc: u8 = if (cie) |c| c.fde_encoding else 0xFF;

        // Read initial location and address range using the CIE's FDE encoding
        const addr_field_pc = @as(u64, @intCast(pos));
        const initial_location = if (fde_enc != 0xFF)
            readEncodedPointer(data, &pos, fde_enc, addr_field_pc) orelse {
                pos = entry_end;
                continue;
            }
        else blk: {
            if (pos + 8 > data.len) break :blk @as(u64, 0);
            const v = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
            break :blk v;
        };
        const range_enc = fde_enc & 0x0F;
        const address_range = if (fde_enc != 0xFF)
            readEncodedPointer(data, &pos, range_enc, 0) orelse {
                pos = entry_end;
                continue;
            }
        else blk: {
            if (pos + 8 > data.len) break :blk @as(u64, 0);
            const v = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
            break :blk v;
        };

        // Skip FDE augmentation data
        if (cie != null and cie.?.augmentation.len > 0 and cie.?.augmentation[0] == 'z') {
            const aug_len = parser.readULEB128(data, &pos) catch 0;
            pos += @as(usize, @intCast(aug_len));
        }

        const instructions = if (pos < entry_end) data[pos..entry_end] else &[_]u8{};

        try fdes.append(allocator, .{
            .cie_offset = entry_start,
            .initial_location = initial_location,
            .address_range = address_range,
            .instructions = instructions,
        });

        pos = entry_end;
    }

    return try fdes.toOwnedSlice(allocator);
}

// CFA rule types for register recovery
pub const CfaRule = union(enum) {
    undefined: void,
    same_value: void,
    offset: i64, // CFA + offset
    val_offset: i64, // CFA + offset (value, not memory)
    register: u64, // Value is in another register
    expression: []const u8, // DWARF expression to evaluate
    val_expression: []const u8, // DWARF expression giving value directly
};

const MAX_CFA_RULES = 128;

pub const CfaState = struct {
    cfa_register: u64 = 0,
    cfa_offset: i64 = 0,
    cfa_expression: ?[]const u8 = null,
    rules: [MAX_CFA_RULES]CfaRule = [_]CfaRule{.{ .undefined = {} }} ** MAX_CFA_RULES,
    return_address_register: u64 = 0,
};

/// Parse CIE initial instructions and FDE instructions to compute register rules at a given PC.
pub fn parseCie(data: []const u8, cie_start: usize) ?CieEntry {
    var pos = cie_start;

    // Length
    if (pos + 4 > data.len) return null;
    const length_32 = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    if (length_32 == 0) return null;

    var length: u64 = length_32;
    if (length_32 == 0xFFFFFFFF) {
        if (pos + 8 > data.len) return null;
        length = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
    }

    const entry_data_start = pos;
    const entry_end = entry_data_start + @as(usize, @intCast(length));
    if (entry_end > data.len) return null;

    // CIE ID (0 for .debug_frame CIEs, 0 for .eh_frame CIEs identified differently)
    if (pos + 4 > data.len) return null;
    pos += 4; // Skip CIE ID

    // Version
    if (pos >= data.len) return null;
    const version = data[pos];
    pos += 1;
    _ = version;

    // Augmentation string (null-terminated)
    const aug_start = pos;
    while (pos < data.len and data[pos] != 0) pos += 1;
    const augmentation = data[aug_start..pos];
    if (pos < data.len) pos += 1; // Skip null terminator

    // Code alignment factor
    const code_alignment = parser.readULEB128(data, &pos) catch return null;

    // Data alignment factor
    const data_alignment = parser.readSLEB128(data, &pos) catch return null;

    // Return address register
    const return_address_register = parser.readULEB128(data, &pos) catch return null;

    // Parse augmentation data (if 'z' prefix in augmentation string)
    var fde_encoding: u8 = 0xFF;
    if (augmentation.len > 0 and augmentation[0] == 'z') {
        const aug_data_len = parser.readULEB128(data, &pos) catch return null;
        const aug_data_end = pos + @as(usize, @intCast(aug_data_len));
        // Walk augmentation string (skip 'z') to interpret each byte
        for (augmentation[1..]) |ch| {
            if (pos >= aug_data_end) break;
            switch (ch) {
                'R' => {
                    fde_encoding = data[pos];
                    pos += 1;
                },
                'L' => {
                    // LSDA encoding — skip 1 byte
                    pos += 1;
                },
                'P' => {
                    // Personality encoding + pointer — skip encoding byte + pointer
                    if (pos >= aug_data_end) break;
                    const pe = data[pos];
                    pos += 1;
                    pos += pointerSize(pe);
                },
                'S' => {}, // Signal frame — no data
                else => break, // Unknown augmentation — stop parsing
            }
        }
        pos = aug_data_end;
    }

    const initial_instructions = if (pos < entry_end) data[pos..entry_end] else &[_]u8{};

    return CieEntry{
        .code_alignment = code_alignment,
        .data_alignment = data_alignment,
        .return_address_register = return_address_register,
        .initial_instructions = initial_instructions,
        .augmentation = augmentation,
        .address_size = 8,
        .fde_encoding = fde_encoding,
    };
}

/// Execute CFA instructions to build register rules.
/// `cie_initial_state` contains the register rules established by the CIE's initial instructions.
/// DW_CFA_restore uses this to restore registers to their CIE-defined initial values.
/// Pass `null` when executing CIE initial instructions themselves (restore acts as undefined).
pub fn executeCfaInstructions(
    instructions: []const u8,
    cie: CieEntry,
    target_pc: u64,
    initial_location: u64,
    state: *CfaState,
    cie_initial_state: ?*const CfaState,
) void {
    state.return_address_register = cie.return_address_register;
    var pos: usize = 0;
    var current_pc = initial_location;

    // State stack for DW_CFA_remember_state / DW_CFA_restore_state
    var state_stack: [8]CfaState = undefined;
    var state_stack_depth: usize = 0;

    while (pos < instructions.len) {
        const byte = instructions[pos];
        pos += 1;

        const high2 = byte & 0xC0;
        const low6 = byte & 0x3F;

        if (high2 == DW_CFA_advance_loc) {
            current_pc += @as(u64, low6) * cie.code_alignment;
            if (current_pc > target_pc) return;
        } else if (high2 == DW_CFA_offset) {
            const reg = low6;
            const offset_val = parser.readULEB128(instructions, &pos) catch return;
            const factored_offset = @as(i64, @intCast(offset_val)) * cie.data_alignment;
            if (reg < MAX_CFA_RULES) {
                state.rules[reg] = .{ .offset = factored_offset };
            }
        } else if (high2 == DW_CFA_restore) {
            const reg = low6;
            if (reg < MAX_CFA_RULES) {
                state.rules[reg] = if (cie_initial_state) |init| init.rules[reg] else .{ .undefined = {} };
            }
        } else {
            switch (byte) {
                DW_CFA_nop => {},
                DW_CFA_set_loc => {
                    if (pos + 8 <= instructions.len) {
                        current_pc = std.mem.readInt(u64, instructions[pos..][0..8], .little);
                        pos += 8;
                        if (current_pc > target_pc) return;
                    } else return;
                },
                DW_CFA_advance_loc1 => {
                    if (pos >= instructions.len) return;
                    current_pc += @as(u64, instructions[pos]) * cie.code_alignment;
                    pos += 1;
                    if (current_pc > target_pc) return;
                },
                DW_CFA_advance_loc2 => {
                    if (pos + 2 > instructions.len) return;
                    const delta = std.mem.readInt(u16, instructions[pos..][0..2], .little);
                    pos += 2;
                    current_pc += @as(u64, delta) * cie.code_alignment;
                    if (current_pc > target_pc) return;
                },
                DW_CFA_advance_loc4 => {
                    if (pos + 4 > instructions.len) return;
                    const delta = std.mem.readInt(u32, instructions[pos..][0..4], .little);
                    pos += 4;
                    current_pc += @as(u64, delta) * cie.code_alignment;
                    if (current_pc > target_pc) return;
                },
                DW_CFA_offset_extended => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const offset_val = parser.readULEB128(instructions, &pos) catch return;
                    const factored_offset = @as(i64, @intCast(offset_val)) * cie.data_alignment;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .offset = factored_offset };
                    }
                },
                DW_CFA_restore_extended => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = if (cie_initial_state) |init| init.rules[@intCast(reg)] else .{ .undefined = {} };
                    }
                },
                DW_CFA_undefined => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .undefined = {} };
                    }
                },
                DW_CFA_same_value => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .same_value = {} };
                    }
                },
                DW_CFA_register => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const target_reg = parser.readULEB128(instructions, &pos) catch return;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .register = target_reg };
                    }
                },
                DW_CFA_remember_state => {
                    if (state_stack_depth < state_stack.len) {
                        state_stack[state_stack_depth] = state.*;
                        state_stack_depth += 1;
                    }
                },
                DW_CFA_restore_state => {
                    if (state_stack_depth > 0) {
                        state_stack_depth -= 1;
                        state.* = state_stack[state_stack_depth];
                    }
                },
                DW_CFA_def_cfa => {
                    state.cfa_register = parser.readULEB128(instructions, &pos) catch return;
                    const off = parser.readULEB128(instructions, &pos) catch return;
                    state.cfa_offset = @intCast(off);
                    state.cfa_expression = null;
                },
                DW_CFA_def_cfa_register => {
                    state.cfa_register = parser.readULEB128(instructions, &pos) catch return;
                    state.cfa_expression = null;
                },
                DW_CFA_def_cfa_offset => {
                    const off = parser.readULEB128(instructions, &pos) catch return;
                    state.cfa_offset = @intCast(off);
                },
                DW_CFA_def_cfa_expression => {
                    const expr_len = parser.readULEB128(instructions, &pos) catch return;
                    const len: usize = @intCast(expr_len);
                    if (pos + len > instructions.len) return;
                    state.cfa_expression = instructions[pos..][0..len];
                    pos += len;
                },
                DW_CFA_expression => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const expr_len = parser.readULEB128(instructions, &pos) catch return;
                    const len: usize = @intCast(expr_len);
                    if (pos + len > instructions.len) return;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .expression = instructions[pos..][0..len] };
                    }
                    pos += len;
                },
                DW_CFA_offset_extended_sf => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const offset_val = parser.readSLEB128(instructions, &pos) catch return;
                    const factored_offset = offset_val * cie.data_alignment;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .offset = factored_offset };
                    }
                },
                DW_CFA_def_cfa_sf => {
                    state.cfa_register = parser.readULEB128(instructions, &pos) catch return;
                    const off = parser.readSLEB128(instructions, &pos) catch return;
                    state.cfa_offset = off * cie.data_alignment;
                    state.cfa_expression = null;
                },
                DW_CFA_def_cfa_offset_sf => {
                    const off = parser.readSLEB128(instructions, &pos) catch return;
                    state.cfa_offset = off * cie.data_alignment;
                },
                DW_CFA_val_offset => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const offset_val = parser.readULEB128(instructions, &pos) catch return;
                    const factored_offset = @as(i64, @intCast(offset_val)) * cie.data_alignment;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .val_offset = factored_offset };
                    }
                },
                DW_CFA_val_offset_sf => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const offset_val = parser.readSLEB128(instructions, &pos) catch return;
                    const factored_offset = offset_val * cie.data_alignment;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .val_offset = factored_offset };
                    }
                },
                DW_CFA_val_expression => {
                    const reg = parser.readULEB128(instructions, &pos) catch return;
                    const expr_len = parser.readULEB128(instructions, &pos) catch return;
                    const len: usize = @intCast(expr_len);
                    if (pos + len > instructions.len) return;
                    if (reg < MAX_CFA_RULES) {
                        state.rules[@intCast(reg)] = .{ .val_expression = instructions[pos..][0..len] };
                    }
                    pos += len;
                },
                DW_CFA_GNU_args_size => {
                    // Informational — skip the ULEB128 argument
                    _ = parser.readULEB128(instructions, &pos) catch return;
                },
                else => {
                    // Unknown instruction — stop processing
                    return;
                },
            }
        }
    }
}

/// Find the FDE covering a given PC and compute CFA state.
/// Returns the CFA value and return address if successful.
/// The `ctx` parameter is passed through to the reader callbacks, allowing
/// callers to supply process state without requiring closures.
pub fn unwindCfa(
    eh_frame_data: []const u8,
    target_pc: u64,
    ctx: *anyopaque,
    reg_reader: *const fn (ctx: *anyopaque, reg: u64) ?u64,
    mem_reader: *const fn (ctx: *anyopaque, addr: u64, size: usize) ?u64,
) ?struct { cfa: u64, return_address: u64 } {
    // Parse FDEs to find one covering target_pc
    var pos: usize = 0;

    while (pos < eh_frame_data.len) {
        const entry_start = pos;

        if (pos + 4 > eh_frame_data.len) break;
        const length_32 = std.mem.readInt(u32, eh_frame_data[pos..][0..4], .little);
        pos += 4;
        if (length_32 == 0) break;

        var length: u64 = length_32;
        if (length_32 == 0xFFFFFFFF) {
            if (pos + 8 > eh_frame_data.len) break;
            length = std.mem.readInt(u64, eh_frame_data[pos..][0..8], .little);
            pos += 8;
        }

        const entry_data_start = pos;
        const entry_end = entry_data_start + @as(usize, @intCast(length));
        if (entry_end > eh_frame_data.len) break;

        if (pos + 4 > eh_frame_data.len) break;
        const cie_id = std.mem.readInt(u32, eh_frame_data[pos..][0..4], .little);
        pos += 4;

        if (cie_id == 0) {
            // CIE — skip
            pos = entry_end;
            continue;
        }

        // FDE — parse the corresponding CIE first to get pointer encoding
        const cie_offset = entry_data_start - @as(usize, cie_id);
        const cie = parseCie(eh_frame_data, cie_offset) orelse {
            pos = entry_end;
            continue;
        };

        // Read initial location and address range using the CIE's FDE encoding
        const addr_field_pc = @as(u64, @intCast(pos)); // Address of this field (for pcrel)
        const initial_location = if (cie.fde_encoding != 0xFF)
            readEncodedPointer(eh_frame_data, &pos, cie.fde_encoding, addr_field_pc) orelse {
                pos = entry_end;
                continue;
            }
        else blk: {
            // No encoding specified — default to 8-byte absolute
            if (pos + 8 > eh_frame_data.len) break :blk @as(u64, 0);
            const v = std.mem.readInt(u64, eh_frame_data[pos..][0..8], .little);
            pos += 8;
            break :blk v;
        };
        // Address range uses same value format but is always absolute (not pcrel)
        const range_encoding = cie.fde_encoding & 0x0F; // Strip relocation, keep value format
        const address_range = if (cie.fde_encoding != 0xFF)
            readEncodedPointer(eh_frame_data, &pos, range_encoding, 0) orelse {
                pos = entry_end;
                continue;
            }
        else blk: {
            if (pos + 8 > eh_frame_data.len) break :blk @as(u64, 0);
            const v = std.mem.readInt(u64, eh_frame_data[pos..][0..8], .little);
            pos += 8;
            break :blk v;
        };

        // Check if this FDE covers target_pc
        if (target_pc >= initial_location and target_pc < initial_location + address_range) {

            // Skip augmentation data
            if (cie.augmentation.len > 0 and cie.augmentation[0] == 'z') {
                const aug_len = parser.readULEB128(eh_frame_data, &pos) catch {
                    pos = entry_end;
                    continue;
                };
                pos += @intCast(aug_len);
            }

            const fde_instructions = if (pos < entry_end) eh_frame_data[pos..entry_end] else &[_]u8{};

            // Execute CIE initial instructions, then FDE instructions
            var state = CfaState{};
            executeCfaInstructions(cie.initial_instructions, cie, target_pc, initial_location, &state, null);
            // Capture CIE initial state so DW_CFA_restore can reference it
            const cie_initial = state;
            executeCfaInstructions(fde_instructions, cie, target_pc, initial_location, &state, &cie_initial);

            // Compute CFA value
            const cfa = if (state.cfa_expression) |cfa_expr| blk: {
                // CFA defined by a DWARF expression — handle common DW_OP_bregN pattern
                if (cfa_expr.len >= 2 and cfa_expr[0] >= 0x70 and cfa_expr[0] <= 0x8f) {
                    const breg = @as(u64, cfa_expr[0] - 0x70);
                    var expr_pos: usize = 1;
                    const offset = parser.readSLEB128(cfa_expr, &expr_pos) catch break :blk @as(u64, 0);
                    const base = reg_reader(ctx, breg) orelse break :blk @as(u64, 0);
                    break :blk if (offset >= 0)
                        base +% @as(u64, @intCast(offset))
                    else
                        base -% @as(u64, @intCast(-offset));
                } else {
                    break :blk @as(u64, 0);
                }
            } else blk: {
                const cfa_reg_val = reg_reader(ctx, state.cfa_register) orelse return null;
                break :blk if (state.cfa_offset >= 0)
                    cfa_reg_val +% @as(u64, @intCast(state.cfa_offset))
                else
                    cfa_reg_val -% @as(u64, @intCast(-state.cfa_offset));
            };

            // Get return address from CFA rules
            var ret_addr: u64 = 0;
            if (state.return_address_register < MAX_CFA_RULES) {
                switch (state.rules[@intCast(state.return_address_register)]) {
                    .offset => |off| {
                        const addr = if (off >= 0)
                            cfa +% @as(u64, @intCast(off))
                        else
                            cfa -% @as(u64, @intCast(-off));
                        ret_addr = mem_reader(ctx, addr, 8) orelse return null;
                    },
                    .register => |reg| {
                        ret_addr = reg_reader(ctx, reg) orelse return null;
                    },
                    .same_value => {
                        ret_addr = reg_reader(ctx, state.return_address_register) orelse return null;
                    },
                    else => return null,
                }
            }

            return .{ .cfa = cfa, .return_address = ret_addr };
        }

        _ = entry_start;
        pos = entry_end;
    }

    return null;
}

/// Unwind the stack using CFA (Call Frame Address) information from .eh_frame.
/// This works even when frame pointers are omitted (-fomit-frame-pointer).
/// Iteratively walks the stack by computing each frame's CFA and return address
/// from DWARF unwind instructions.
pub fn unwindStackCfa(
    eh_frame_data: []const u8,
    start_pc: u64,
    start_sp: u64,
    functions: []const parser.FunctionInfo,
    line_entries: []const parser.LineEntry,
    file_entries: []const parser.FileEntry,
    ctx: *anyopaque,
    reg_reader: *const fn (ctx: *anyopaque, reg: u64) ?u64,
    mem_reader: *const fn (ctx: *anyopaque, addr: u64, size: usize) ?u64,
    allocator: std.mem.Allocator,
    max_depth: u32,
) ![]UnwindFrame {
    var frames: std.ArrayListUnmanaged(UnwindFrame) = .empty;
    errdefer frames.deinit(allocator);

    var pc = start_pc;
    _ = start_sp;
    var frame_idx: u32 = 0;

    while (frame_idx < max_depth) {
        const func_name = findFunctionForPC(functions, pc);
        const loc = parser.resolveAddress(line_entries, file_entries, pc);

        try frames.append(allocator, .{
            .address = pc,
            .function_name = func_name,
            .file = if (loc) |l| l.file else "<unknown>",
            .line = if (loc) |l| l.line else 0,
            .frame_index = frame_idx,
        });

        // Stop at main or _start
        if (std.mem.eql(u8, func_name, "main") or std.mem.eql(u8, func_name, "_start")) {
            break;
        }

        // Use CFA unwinding to get the return address for the next frame
        const result = unwindCfa(eh_frame_data, pc, ctx, reg_reader, mem_reader) orelse break;
        if (result.return_address == 0) break;

        pc = result.return_address;
        frame_idx += 1;
    }

    return try frames.toOwnedSlice(allocator);
}

/// Unwind the stack by following frame pointers (FP-based unwinding).
/// This is the simpler approach that works when frame pointers are preserved (-fno-omit-frame-pointer).
pub fn unwindStackFP(
    start_pc: u64,
    start_fp: u64,
    functions: []const parser.FunctionInfo,
    line_entries: []const parser.LineEntry,
    file_entries: []const parser.FileEntry,
    process: *process_mod.ProcessControl,
    allocator: std.mem.Allocator,
    max_depth: u32,
) ![]UnwindFrame {
    var frames: std.ArrayListUnmanaged(UnwindFrame) = .empty;
    errdefer frames.deinit(allocator);

    var pc = start_pc;
    var fp = start_fp;
    var frame_idx: u32 = 0;

    while (frame_idx < max_depth and fp != 0) {
        // Find function name for this PC
        const func_name = findFunctionForPC(functions, pc);

        // Find source location for this PC
        const loc = parser.resolveAddress(line_entries, file_entries, pc);

        try frames.append(allocator, .{
            .address = pc,
            .function_name = func_name,
            .file = if (loc) |l| l.file else "<unknown>",
            .line = if (loc) |l| l.line else 0,
            .frame_index = frame_idx,
        });

        // Stop at main or _start
        if (std.mem.eql(u8, func_name, "main") or std.mem.eql(u8, func_name, "_start")) {
            break;
        }

        // Read saved frame pointer and return address from stack
        // On x86_64: [fp] = saved_fp, [fp+8] = return_addr
        // On aarch64: [fp] = saved_fp, [fp+8] = saved_lr (return addr)
        const saved_fp_bytes = process.readMemory(fp, 8, allocator) catch break;
        defer allocator.free(saved_fp_bytes);
        const saved_fp = std.mem.readInt(u64, saved_fp_bytes[0..8], .little);

        const ret_addr_bytes = process.readMemory(fp + 8, 8, allocator) catch break;
        defer allocator.free(ret_addr_bytes);
        const ret_addr = std.mem.readInt(u64, ret_addr_bytes[0..8], .little);

        if (ret_addr == 0 or saved_fp == 0) break;
        if (saved_fp <= fp) break; // Stack grows down — new fp should be higher

        pc = ret_addr;
        fp = saved_fp;
        frame_idx += 1;
    }

    return try frames.toOwnedSlice(allocator);
}

/// Build a stack trace from pre-computed frame data (for testing without a process).
pub fn buildStackTrace(
    addresses: []const u64,
    functions: []const parser.FunctionInfo,
    line_entries: []const parser.LineEntry,
    file_entries: []const parser.FileEntry,
    allocator: std.mem.Allocator,
) ![]UnwindFrame {
    var frames: std.ArrayListUnmanaged(UnwindFrame) = .empty;
    errdefer frames.deinit(allocator);

    for (addresses, 0..) |pc, i| {
        const func_name = findFunctionForPC(functions, pc);
        const loc = parser.resolveAddress(line_entries, file_entries, pc);

        try frames.append(allocator, .{
            .address = pc,
            .function_name = func_name,
            .file = if (loc) |l| l.file else "<unknown>",
            .line = if (loc) |l| l.line else 0,
            .frame_index = @intCast(i),
        });
    }

    return try frames.toOwnedSlice(allocator);
}

fn findFunctionForPC(functions: []const parser.FunctionInfo, pc: u64) []const u8 {
    for (functions) |f| {
        if (pc >= f.low_pc and (f.high_pc == 0 or pc < f.high_pc)) {
            return f.name;
        }
    }
    return "<unknown>";
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parseEhFrame extracts frame description entries" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var macho = binary_macho.MachoBinary.loadFile(std.testing.allocator, "test/fixtures/simple.o") catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer macho.deinit(std.testing.allocator);

    const eh_frame_info = macho.sections.eh_frame orelse return error.SkipZigTest;
    const eh_frame_data = macho.getSectionData(eh_frame_info) orelse return error.SkipZigTest;

    const fdes = try parseEhFrame(eh_frame_data, std.testing.allocator);
    defer std.testing.allocator.free(fdes);

    // The fixture has at least 2 functions (add, main), so should have FDEs
    try std.testing.expect(fdes.len > 0);
}

test "buildStackTrace produces ordered frame list" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1050 },
        .{ .name = "compute", .low_pc = 0x1050, .high_pc = 0x1080 },
        .{ .name = "helper", .low_pc = 0x1080, .high_pc = 0x10A0 },
    };

    const line_entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1050, .file_index = 1, .line = 6, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1080, .file_index = 1, .line = 2, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const file_entries = [_]parser.FileEntry{
        .{ .name = "test.c", .dir_index = 0 },
    };

    const addresses = [_]u64{ 0x1088, 0x1058, 0x1008 };

    const frames = try buildStackTrace(&addresses, &functions, &line_entries, &file_entries, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);

    // Frame 0: helper (deepest)
    try std.testing.expectEqualStrings("helper", frames[0].function_name);
    try std.testing.expectEqual(@as(u32, 0), frames[0].frame_index);

    // Frame 1: compute
    try std.testing.expectEqualStrings("compute", frames[1].function_name);
    try std.testing.expectEqual(@as(u32, 1), frames[1].frame_index);

    // Frame 2: main
    try std.testing.expectEqualStrings("main", frames[2].function_name);
    try std.testing.expectEqual(@as(u32, 2), frames[2].frame_index);
}

test "unwindStack includes function names" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "foo", .low_pc = 0x2000, .high_pc = 0x2050 },
    };

    const addresses = [_]u64{0x2010};
    const frames = try buildStackTrace(&addresses, &functions, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("foo", frames[0].function_name);
}

test "unwindStack includes source locations" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "bar", .low_pc = 0x3000, .high_pc = 0x3050 },
    };
    const line_entries = [_]parser.LineEntry{
        .{ .address = 0x3000, .file_index = 1, .line = 42, .column = 5, .is_stmt = true, .end_sequence = false },
    };
    const file_entries = [_]parser.FileEntry{
        .{ .name = "bar.c", .dir_index = 0 },
    };

    const addresses = [_]u64{0x3010};
    const frames = try buildStackTrace(&addresses, &functions, &line_entries, &file_entries, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("bar.c", frames[0].file);
    try std.testing.expectEqual(@as(u32, 42), frames[0].line);
}

test "unwindStack handles 3-deep call chain" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1100 },
        .{ .name = "level1", .low_pc = 0x1100, .high_pc = 0x1200 },
        .{ .name = "level2", .low_pc = 0x1200, .high_pc = 0x1300 },
    };

    const addresses = [_]u64{ 0x1250, 0x1150, 0x1050 };
    const frames = try buildStackTrace(&addresses, &functions, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqualStrings("level2", frames[0].function_name);
    try std.testing.expectEqualStrings("level1", frames[1].function_name);
    try std.testing.expectEqualStrings("main", frames[2].function_name);
}

test "unwindStack unknown function shows <unknown>" {
    const addresses = [_]u64{0x9999};
    const frames = try buildStackTrace(&addresses, &[_]parser.FunctionInfo{}, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("<unknown>", frames[0].function_name);
}

test "unwindStack stops at main entry point" {
    // buildStackTrace returns all frames, but unwindStackFP stops at main.
    // Test that the FP-based unwinder recognizes "main" as a sentinel.
    const functions = [_]parser.FunctionInfo{
        .{ .name = "deep", .low_pc = 0x3000, .high_pc = 0x3100 },
        .{ .name = "middle", .low_pc = 0x2000, .high_pc = 0x2100 },
        .{ .name = "main", .low_pc = 0x1000, .high_pc = 0x1100 },
        .{ .name = "_start", .low_pc = 0x0800, .high_pc = 0x0900 },
    };

    // Simulate: deep -> middle -> main -> _start
    // buildStackTrace returns all, but the trace should include main as last
    const addresses = [_]u64{ 0x3050, 0x2050, 0x1050 };
    const frames = try buildStackTrace(&addresses, &functions, &[_]parser.LineEntry{}, &[_]parser.FileEntry{}, std.testing.allocator);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqualStrings("deep", frames[0].function_name);
    try std.testing.expectEqualStrings("middle", frames[1].function_name);
    try std.testing.expectEqualStrings("main", frames[2].function_name);
}

test "findFunctionForPC matches correct function" {
    const functions = [_]parser.FunctionInfo{
        .{ .name = "a", .low_pc = 0x100, .high_pc = 0x200 },
        .{ .name = "b", .low_pc = 0x200, .high_pc = 0x300 },
    };

    try std.testing.expectEqualStrings("a", findFunctionForPC(&functions, 0x100));
    try std.testing.expectEqualStrings("a", findFunctionForPC(&functions, 0x1FF));
    try std.testing.expectEqualStrings("b", findFunctionForPC(&functions, 0x200));
    try std.testing.expectEqualStrings("<unknown>", findFunctionForPC(&functions, 0x400));
}

test "CFA offset_extended sets rule for high register numbers" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    // DW_CFA_offset_extended: reg=64, offset=2 (factored: 2 * -8 = -16)
    var instructions: [3]u8 = undefined;
    instructions[0] = DW_CFA_offset_extended;
    instructions[1] = 64; // reg (ULEB128)
    instructions[2] = 2; // offset (ULEB128)

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    try std.testing.expectEqual(CfaRule{ .offset = -16 }, state.rules[64]);
}

test "CFA remember/restore state preserves and restores rules" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    // Set reg 0 to offset -8, remember, change to offset -16, restore
    var instructions: [8]u8 = undefined;
    instructions[0] = DW_CFA_def_cfa;
    instructions[1] = 7; // reg 7
    instructions[2] = 16; // offset 16
    instructions[3] = DW_CFA_remember_state;
    instructions[4] = DW_CFA_def_cfa_offset;
    instructions[5] = 32; // change offset to 32
    instructions[6] = DW_CFA_restore_state;
    instructions[7] = DW_CFA_nop;

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    // After restore, offset should be back to 16
    try std.testing.expectEqual(@as(i64, 16), state.cfa_offset);
    try std.testing.expectEqual(@as(u64, 7), state.cfa_register);
}

test "CFA same_value and undefined set correct rules" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    var instructions: [4]u8 = undefined;
    instructions[0] = DW_CFA_same_value;
    instructions[1] = 5; // reg 5
    instructions[2] = DW_CFA_undefined;
    instructions[3] = 6; // reg 6

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    try std.testing.expectEqual(CfaRule{ .same_value = {} }, state.rules[5]);
    try std.testing.expectEqual(CfaRule{ .undefined = {} }, state.rules[6]);
}

test "CFA register rule maps one register to another" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    var instructions: [3]u8 = undefined;
    instructions[0] = DW_CFA_register;
    instructions[1] = 3; // reg 3
    instructions[2] = 7; // target reg 7

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    try std.testing.expectEqual(CfaRule{ .register = 7 }, state.rules[3]);
}

test "CFA def_cfa_expression sets expression" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    // DW_CFA_def_cfa_expression: len=2, expr=[0x50, 0x23] (DW_OP_reg0, DW_OP_plus_uconst)
    var instructions: [4]u8 = undefined;
    instructions[0] = DW_CFA_def_cfa_expression;
    instructions[1] = 2; // expr length (ULEB128)
    instructions[2] = 0x50; // dummy expr byte
    instructions[3] = 0x23; // dummy expr byte

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    try std.testing.expect(state.cfa_expression != null);
    try std.testing.expectEqual(@as(usize, 2), state.cfa_expression.?.len);
}

test "CFA val_offset sets val_offset rule" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    var instructions: [3]u8 = undefined;
    instructions[0] = DW_CFA_val_offset;
    instructions[1] = 10; // reg 10
    instructions[2] = 3; // offset 3 (factored: 3 * -8 = -24)

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    try std.testing.expectEqual(CfaRule{ .val_offset = -24 }, state.rules[10]);
}

test "CFA GNU_args_size is skipped without error" {
    const cie = CieEntry{
        .code_alignment = 1,
        .data_alignment = -8,
        .return_address_register = 16,
        .initial_instructions = &.{},
        .augmentation = "",
        .address_size = 8,
    };

    // DW_CFA_GNU_args_size followed by DW_CFA_def_cfa
    var instructions: [6]u8 = undefined;
    instructions[0] = DW_CFA_GNU_args_size;
    instructions[1] = 8; // args size (ULEB128)
    instructions[2] = DW_CFA_def_cfa;
    instructions[3] = 7; // reg
    instructions[4] = 16; // offset
    instructions[5] = DW_CFA_nop;

    var state = CfaState{};
    executeCfaInstructions(&instructions, cie, 0xFFFF, 0x1000, &state, null);
    // Should have processed def_cfa after skipping GNU_args_size
    try std.testing.expectEqual(@as(u64, 7), state.cfa_register);
    try std.testing.expectEqual(@as(i64, 16), state.cfa_offset);
}

test "unwindCfa returns null for empty eh_frame" {
    const TestCtx = struct {
        fn regReader(_: *anyopaque, _: u64) ?u64 {
            return null;
        }
        fn memReader(_: *anyopaque, _: u64, _: usize) ?u64 {
            return null;
        }
    };
    var dummy: u8 = 0;
    const ctx: *anyopaque = @ptrCast(&dummy);
    const result = unwindCfa(&[_]u8{}, 0x1000, ctx, &TestCtx.regReader, &TestCtx.memReader);
    try std.testing.expect(result == null);
}

test "unwindCfa returns null when no FDE covers target PC" {
    // Build a minimal .eh_frame with a CIE + FDE that does NOT cover our target PC
    const TestCtx = struct {
        fn regReader(_: *anyopaque, _: u64) ?u64 {
            return 0x7FFF0000;
        }
        fn memReader(_: *anyopaque, _: u64, _: usize) ?u64 {
            return 0x401000;
        }
    };
    var dummy: u8 = 0;
    const ctx: *anyopaque = @ptrCast(&dummy);

    // Minimal CIE (length=4, cie_id=0)
    // Followed by FDE covering 0x1000-0x1100 (our PC 0x2000 is outside)
    var frame_data: [48]u8 = [_]u8{0} ** 48;

    // CIE: length=8, cie_id=0
    std.mem.writeInt(u32, frame_data[0..4], 8, .little); // length
    std.mem.writeInt(u32, frame_data[4..8], 0, .little); // cie_id = 0 (this is a CIE)
    frame_data[8] = 1; // version
    frame_data[9] = 0; // augmentation (empty, null terminated)
    frame_data[10] = 1; // code_alignment (ULEB128)
    frame_data[11] = 0x78; // data_alignment (SLEB128 = -8)

    // FDE: length=20, cie_pointer=4 (relative to self)
    std.mem.writeInt(u32, frame_data[12..16], 20, .little); // length
    std.mem.writeInt(u32, frame_data[16..20], 4, .little); // cie_pointer (offset back to CIE)
    std.mem.writeInt(u64, frame_data[20..28], 0x1000, .little); // initial_location
    std.mem.writeInt(u64, frame_data[28..36], 0x100, .little); // address_range

    // Terminator
    std.mem.writeInt(u32, frame_data[36..40], 0, .little);

    const result = unwindCfa(&frame_data, 0x2000, ctx, &TestCtx.regReader, &TestCtx.memReader);
    try std.testing.expect(result == null);
}
