const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");

// ── DWARF Location Expression Evaluation ───────────────────────────────

// DWARF expression opcodes
const DW_OP_addr: u8 = 0x03;
const DW_OP_deref: u8 = 0x06;
const DW_OP_const1u: u8 = 0x08;
const DW_OP_const1s: u8 = 0x09;
const DW_OP_const2u: u8 = 0x0a;
const DW_OP_const2s: u8 = 0x0b;
const DW_OP_const4u: u8 = 0x0c;
const DW_OP_const4s: u8 = 0x0d;
const DW_OP_const8u: u8 = 0x0e;
const DW_OP_const8s: u8 = 0x0f;
const DW_OP_constu: u8 = 0x10;
const DW_OP_consts: u8 = 0x11;
const DW_OP_dup: u8 = 0x12;
const DW_OP_drop: u8 = 0x13;
const DW_OP_plus: u8 = 0x22;
const DW_OP_plus_uconst: u8 = 0x23;
const DW_OP_minus: u8 = 0x1c;
const DW_OP_mul: u8 = 0x1e;
const DW_OP_lit0: u8 = 0x30;
const DW_OP_lit31: u8 = 0x4f;
const DW_OP_reg0: u8 = 0x50;
const DW_OP_reg31: u8 = 0x6f;
const DW_OP_breg0: u8 = 0x70;
const DW_OP_breg31: u8 = 0x8f;
const DW_OP_over: u8 = 0x14;
const DW_OP_pick: u8 = 0x15;
const DW_OP_swap: u8 = 0x16;
const DW_OP_rot: u8 = 0x17;
const DW_OP_abs: u8 = 0x19;
const DW_OP_and: u8 = 0x1a;
const DW_OP_div: u8 = 0x1b;
const DW_OP_mod: u8 = 0x1d;
const DW_OP_neg: u8 = 0x1f;
const DW_OP_not: u8 = 0x20;
const DW_OP_or: u8 = 0x21;
const DW_OP_shl: u8 = 0x24;
const DW_OP_shr: u8 = 0x25;
const DW_OP_shra: u8 = 0x26;
const DW_OP_xor: u8 = 0x27;
const DW_OP_skip: u8 = 0x2f;
const DW_OP_bra: u8 = 0x28;
const DW_OP_eq: u8 = 0x29;
const DW_OP_ge: u8 = 0x2a;
const DW_OP_gt: u8 = 0x2b;
const DW_OP_le: u8 = 0x2c;
const DW_OP_lt: u8 = 0x2d;
const DW_OP_ne: u8 = 0x2e;
const DW_OP_regx: u8 = 0x90;
const DW_OP_fbreg: u8 = 0x91;
const DW_OP_bregx: u8 = 0x92;
const DW_OP_stack_value: u8 = 0x9f;
const DW_OP_piece: u8 = 0x93;
const DW_OP_deref_size: u8 = 0x94;
const DW_OP_call_frame_cfa: u8 = 0x9c;
const DW_OP_implicit_value: u8 = 0x9e;
const DW_OP_entry_value: u8 = 0xa3;
const DW_OP_GNU_entry_value: u8 = 0xf3;
const DW_OP_xderef: u8 = 0x18;
const DW_OP_xderef_size: u8 = 0x95;
const DW_OP_nop: u8 = 0x96;
const DW_OP_push_object_address: u8 = 0x97;
const DW_OP_call2: u8 = 0x98;
const DW_OP_call4: u8 = 0x99;
const DW_OP_call_ref: u8 = 0x9a;
const DW_OP_form_tls_address: u8 = 0x9b;
const DW_OP_bit_piece: u8 = 0x9d;
const DW_OP_implicit_pointer: u8 = 0xa0;
const DW_OP_addrx: u8 = 0xa1;
const DW_OP_constx: u8 = 0xa2;
const DW_OP_const_type: u8 = 0xa4;
const DW_OP_regval_type: u8 = 0xa5;
const DW_OP_deref_type: u8 = 0xa6;
const DW_OP_convert: u8 = 0xa8;
const DW_OP_reinterpret: u8 = 0xa9;

// DWARF base type constants
const DW_ATE_signed: u8 = 0x05;
const DW_ATE_unsigned: u8 = 0x07;
const DW_ATE_float: u8 = 0x04;
const DW_ATE_boolean: u8 = 0x02;
const DW_ATE_address: u8 = 0x01;
const DW_ATE_signed_char: u8 = 0x06;
const DW_ATE_unsigned_char: u8 = 0x08;

pub const LocationResult = union(enum) {
    address: u64,
    register: u64,
    value: u64,
    empty: void,
    implicit_pointer: struct { die_offset: u64, offset: i64 },
    composite: []const LocationPiece,
};

pub const LocationPiece = struct {
    location: PieceLocation,
    size_bits: u64,
    bit_offset: u64 = 0,

    pub const PieceLocation = union(enum) {
        address: u64,
        register: u64,
        value: u64,
        empty: void,
    };
};

/// Extended context for location expression evaluation.
/// Bundles optional parameters that specific DW_OP codes need.
pub const LocationContext = struct {
    /// Register values captured at function entry (for DW_OP_entry_value)
    entry_regs: ?RegisterProvider = null,
    /// Object address for DW_OP_push_object_address (e.g., when evaluating DW_AT_data_location)
    object_address: ?u64 = null,
    /// .debug_info section data for DW_OP_call2/call4/call_ref
    debug_info: ?[]const u8 = null,
    /// .debug_abbrev section data for DW_OP_call2/call4/call_ref
    debug_abbrev: ?[]const u8 = null,
    /// TLS base address for DW_OP_form_tls_address
    tls_base: ?u64 = null,
    /// .debug_addr section data for DW_OP_addrx/constx
    debug_addr: ?[]const u8 = null,
    /// Base offset into .debug_addr for this compilation unit (from DW_AT_addr_base)
    addr_base: u64 = 0,
    /// Address size in bytes (4 for 32-bit targets, 8 for 64-bit)
    address_size: u8 = 8,
    /// Whether the compilation unit uses DWARF-64 format (affects DW_OP_call_ref, DW_OP_implicit_pointer)
    is_dwarf64: bool = false,
    /// Canonical Frame Address from .eh_frame/.debug_frame (for DW_OP_call_frame_cfa)
    cfa: ?u64 = null,
};

pub const VariableValue = struct {
    name: []const u8,
    value_str: []const u8,
    type_str: []const u8,
};

pub const RegisterProvider = struct {
    ptr: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, reg: u64) ?u64,

    pub fn read(self: RegisterProvider, reg: u64) ?u64 {
        return self.readFn(self.ptr, reg);
    }
};

pub const MemoryReader = struct {
    ptr: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, addr: u64, size: usize) ?u64,

    pub fn read(self: MemoryReader, addr: u64, size: usize) ?u64 {
        return self.readFn(self.ptr, addr, size);
    }
};

// ── Location List Evaluation ───────────────────────────────────────────

// DWARF 5 location list entry kinds
const DW_LLE_end_of_list: u8 = 0x00;
const DW_LLE_base_addressx: u8 = 0x01;
const DW_LLE_startx_endx: u8 = 0x02;
const DW_LLE_startx_length: u8 = 0x03;
const DW_LLE_offset_pair: u8 = 0x04;
const DW_LLE_default_location: u8 = 0x05;
const DW_LLE_base_address: u8 = 0x06;
const DW_LLE_start_end: u8 = 0x07;
const DW_LLE_start_length: u8 = 0x08;

/// Evaluate a DWARF 4 location list (.debug_loc) at a given PC.
/// Returns the location expression that applies at the given PC.
pub fn evalLocationList(
    loc_data: []const u8,
    loc_offset: u64,
    pc: u64,
    base_address: u64,
) ?[]const u8 {
    if (loc_offset >= loc_data.len) return null;
    var pos: usize = @intCast(loc_offset);
    var base = base_address;

    while (pos + 16 <= loc_data.len) {
        const begin = std.mem.readInt(u64, loc_data[pos..][0..8], .little);
        pos += 8;
        const end = std.mem.readInt(u64, loc_data[pos..][0..8], .little);
        pos += 8;

        // End of list
        if (begin == 0 and end == 0) return null;

        // Base address selection entry
        if (begin == std.math.maxInt(u64)) {
            base = end;
            continue;
        }

        // Regular entry - read location expression
        if (pos + 2 > loc_data.len) return null;
        const expr_len = std.mem.readInt(u16, loc_data[pos..][0..2], .little);
        pos += 2;

        const expr_end = pos + expr_len;
        if (expr_end > loc_data.len) return null;

        const actual_begin = base + begin;
        const actual_end = base + end;

        if (pc >= actual_begin and pc < actual_end) {
            return loc_data[pos..expr_end];
        }

        pos = expr_end;
    }

    return null;
}

/// Evaluate a DWARF 5 location list (.debug_loclists) at a given PC.
/// Returns the location expression that applies at the given PC.
pub fn evalLocationListDwarf5(
    loclists_data: []const u8,
    loc_offset: u64,
    pc: u64,
    base_address: u64,
    debug_addr: ?[]const u8,
    addr_base: u64,
) ?[]const u8 {
    if (loc_offset >= loclists_data.len) return null;
    var pos: usize = @intCast(loc_offset);
    var base = base_address;
    var default_expr: ?[]const u8 = null;

    while (pos < loclists_data.len) {
        const kind = loclists_data[pos];
        pos += 1;

        switch (kind) {
            DW_LLE_end_of_list => return null,
            DW_LLE_base_address => {
                if (pos + 8 > loclists_data.len) return null;
                base = std.mem.readInt(u64, loclists_data[pos..][0..8], .little);
                pos += 8;
            },
            DW_LLE_offset_pair => {
                const begin = parser.readULEB128(loclists_data, &pos) catch return null;
                const end = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_len = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_end = pos + @as(usize, @intCast(expr_len));
                if (expr_end > loclists_data.len) return null;

                const actual_begin = base + begin;
                const actual_end = base + end;
                if (pc >= actual_begin and pc < actual_end) {
                    return loclists_data[pos..expr_end];
                }
                pos = expr_end;
            },
            DW_LLE_start_end => {
                if (pos + 16 > loclists_data.len) return null;
                const begin = std.mem.readInt(u64, loclists_data[pos..][0..8], .little);
                pos += 8;
                const end = std.mem.readInt(u64, loclists_data[pos..][0..8], .little);
                pos += 8;
                const expr_len = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_end = pos + @as(usize, @intCast(expr_len));
                if (expr_end > loclists_data.len) return null;

                if (pc >= begin and pc < end) {
                    return loclists_data[pos..expr_end];
                }
                pos = expr_end;
            },
            DW_LLE_start_length => {
                if (pos + 8 > loclists_data.len) return null;
                const begin = std.mem.readInt(u64, loclists_data[pos..][0..8], .little);
                pos += 8;
                const length = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_len = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_end = pos + @as(usize, @intCast(expr_len));
                if (expr_end > loclists_data.len) return null;

                if (pc >= begin and pc < begin + length) {
                    return loclists_data[pos..expr_end];
                }
                pos = expr_end;
            },
            DW_LLE_default_location => {
                const expr_len = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_end = pos + @as(usize, @intCast(expr_len));
                if (expr_end > loclists_data.len) return null;
                // Save default and continue — only use if no range matches
                default_expr = loclists_data[pos..expr_end];
                pos = expr_end;
            },
            DW_LLE_base_addressx => {
                const index = parser.readULEB128(loclists_data, &pos) catch return null;
                if (debug_addr) |addr_data| {
                    const offset = addr_base + index * 8;
                    if (offset + 8 <= addr_data.len) {
                        base = std.mem.readInt(u64, addr_data[@intCast(offset)..][0..8], .little);
                    } else return null;
                } else return null;
            },
            DW_LLE_startx_endx => {
                const start_idx = parser.readULEB128(loclists_data, &pos) catch return null;
                const end_idx = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_len = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_end = pos + @as(usize, @intCast(expr_len));
                if (expr_end > loclists_data.len) return null;

                if (debug_addr) |addr_data| {
                    const start_off = addr_base + start_idx * 8;
                    const end_off = addr_base + end_idx * 8;
                    if (start_off + 8 <= addr_data.len and end_off + 8 <= addr_data.len) {
                        const begin = std.mem.readInt(u64, addr_data[@intCast(start_off)..][0..8], .little);
                        const end = std.mem.readInt(u64, addr_data[@intCast(end_off)..][0..8], .little);
                        if (pc >= begin and pc < end) {
                            return loclists_data[pos..expr_end];
                        }
                    }
                }
                pos = expr_end;
            },
            DW_LLE_startx_length => {
                const start_idx = parser.readULEB128(loclists_data, &pos) catch return null;
                const length = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_len = parser.readULEB128(loclists_data, &pos) catch return null;
                const expr_end = pos + @as(usize, @intCast(expr_len));
                if (expr_end > loclists_data.len) return null;

                if (debug_addr) |addr_data| {
                    const start_off = addr_base + start_idx * 8;
                    if (start_off + 8 <= addr_data.len) {
                        const begin = std.mem.readInt(u64, addr_data[@intCast(start_off)..][0..8], .little);
                        if (pc >= begin and pc < begin + length) {
                            return loclists_data[pos..expr_end];
                        }
                    }
                }
                pos = expr_end;
            },
            else => return null,
        }
    }

    return default_expr;
}

/// Evaluate a DWARF location expression with optional memory reader for DW_OP_deref.
pub fn evalLocationWithMemory(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
) LocationResult {
    return evalLocationImpl(expr, regs, frame_base, mem_reader, .{});
}

/// Evaluate a DWARF location expression with extended context.
pub fn evalLocationEx(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
    context: LocationContext,
) LocationResult {
    return evalLocationImpl(expr, regs, frame_base, mem_reader, context);
}

/// Evaluate a DWARF location expression.
pub fn evalLocation(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
) LocationResult {
    return evalLocationImpl(expr, regs, frame_base, null, .{});
}

fn evalLocationImpl(
    expr: []const u8,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
    context: LocationContext,
) LocationResult {
    var stack: [64]u64 = undefined;
    var sp: usize = 0;
    // Track composite location pieces
    var pieces: [16]LocationPiece = undefined;
    var piece_count: usize = 0;
    var is_register_result: bool = false;
    var last_register: u64 = 0;

    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;

        if (op >= DW_OP_lit0 and op <= DW_OP_lit31) {
            if (sp >= stack.len) return .empty;
            stack[sp] = op - DW_OP_lit0;
            sp += 1;
            continue;
        }

        if (op >= DW_OP_reg0 and op <= DW_OP_reg31) {
            is_register_result = true;
            last_register = op - DW_OP_reg0;
            // Don't return immediately — a DW_OP_piece may follow
            continue;
        }

        if (op >= DW_OP_breg0 and op <= DW_OP_breg31) {
            const reg_num = op - DW_OP_breg0;
            const offset = parser.readSLEB128(expr, &pos) catch return .empty;
            const reg_val = regs.read(reg_num) orelse return .empty;
            if (sp >= stack.len) return .empty;
            const result = if (offset >= 0)
                reg_val +% @as(u64, @intCast(offset))
            else
                reg_val -% @as(u64, @intCast(-offset));
            stack[sp] = result;
            sp += 1;
            continue;
        }

        switch (op) {
            DW_OP_addr => {
                if (pos + 8 > expr.len) return .empty;
                const addr = std.mem.readInt(u64, expr[pos..][0..8], .little);
                pos += 8;
                if (sp >= stack.len) return .empty;
                stack[sp] = addr;
                sp += 1;
            },
            DW_OP_fbreg => {
                const offset = parser.readSLEB128(expr, &pos) catch return .empty;
                const fb = frame_base orelse return .empty;
                if (sp >= stack.len) return .empty;
                const result = if (offset >= 0)
                    fb +% @as(u64, @intCast(offset))
                else
                    fb -% @as(u64, @intCast(-offset));
                stack[sp] = result;
                sp += 1;
            },
            DW_OP_regx => {
                const reg_num = parser.readULEB128(expr, &pos) catch return .empty;
                is_register_result = true;
                last_register = reg_num;
                // Don't return immediately — a DW_OP_piece may follow
            },
            DW_OP_constu => {
                const val = parser.readULEB128(expr, &pos) catch return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = val;
                sp += 1;
            },
            DW_OP_consts => {
                const val = parser.readSLEB128(expr, &pos) catch return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = @bitCast(val);
                sp += 1;
            },
            DW_OP_const1u => {
                if (pos >= expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = expr[pos];
                pos += 1;
                sp += 1;
            },
            DW_OP_const1s => {
                if (pos >= expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                const s: i8 = @bitCast(expr[pos]);
                stack[sp] = @bitCast(@as(i64, s));
                pos += 1;
                sp += 1;
            },
            DW_OP_const2u => {
                if (pos + 2 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u16, expr[pos..][0..2], .little);
                pos += 2;
                sp += 1;
            },
            DW_OP_const2s => {
                if (pos + 2 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                const s: i16 = @bitCast(std.mem.readInt(u16, expr[pos..][0..2], .little));
                stack[sp] = @bitCast(@as(i64, s));
                pos += 2;
                sp += 1;
            },
            DW_OP_const4u => {
                if (pos + 4 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u32, expr[pos..][0..4], .little);
                pos += 4;
                sp += 1;
            },
            DW_OP_const4s => {
                if (pos + 4 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                const s: i32 = @bitCast(std.mem.readInt(u32, expr[pos..][0..4], .little));
                stack[sp] = @bitCast(@as(i64, s));
                pos += 4;
                sp += 1;
            },
            DW_OP_const8u => {
                if (pos + 8 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u64, expr[pos..][0..8], .little);
                pos += 8;
                sp += 1;
            },
            DW_OP_const8s => {
                if (pos + 8 > expr.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = std.mem.readInt(u64, expr[pos..][0..8], .little);
                pos += 8;
                sp += 1;
            },
            DW_OP_plus => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] +% stack[sp];
            },
            DW_OP_plus_uconst => {
                if (sp < 1) return .empty;
                const val = parser.readULEB128(expr, &pos) catch return .empty;
                stack[sp - 1] = stack[sp - 1] +% val;
            },
            DW_OP_minus => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] -% stack[sp];
            },
            DW_OP_mul => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] *% stack[sp];
            },
            DW_OP_deref => {
                if (sp < 1) return .empty;
                if (mem_reader) |reader| {
                    // Read 8 bytes from the debuggee's memory at the address on stack
                    const val = reader.read(stack[sp - 1], 8) orelse return .{ .address = stack[sp - 1] };
                    stack[sp - 1] = val;
                } else {
                    // No memory reader — return the address to be dereferenced externally
                    return .{ .address = stack[sp - 1] };
                }
            },
            DW_OP_dup => {
                if (sp < 1 or sp >= stack.len) return .empty;
                stack[sp] = stack[sp - 1];
                sp += 1;
            },
            DW_OP_drop => {
                if (sp < 1) return .empty;
                sp -= 1;
            },
            DW_OP_over => {
                if (sp < 2 or sp >= stack.len) return .empty;
                stack[sp] = stack[sp - 2];
                sp += 1;
            },
            DW_OP_pick => {
                if (pos >= expr.len) return .empty;
                const idx = expr[pos];
                pos += 1;
                if (idx >= sp or sp >= stack.len) return .empty;
                stack[sp] = stack[sp - 1 - idx];
                sp += 1;
            },
            DW_OP_swap => {
                if (sp < 2) return .empty;
                const tmp = stack[sp - 1];
                stack[sp - 1] = stack[sp - 2];
                stack[sp - 2] = tmp;
            },
            DW_OP_rot => {
                if (sp < 3) return .empty;
                const top = stack[sp - 1];
                stack[sp - 1] = stack[sp - 2];
                stack[sp - 2] = stack[sp - 3];
                stack[sp - 3] = top;
            },
            DW_OP_abs => {
                if (sp < 1) return .empty;
                const val: i64 = @bitCast(stack[sp - 1]);
                stack[sp - 1] = @bitCast(if (val < 0) -val else val);
            },
            DW_OP_neg => {
                if (sp < 1) return .empty;
                const val: i64 = @bitCast(stack[sp - 1]);
                stack[sp - 1] = @bitCast(-val);
            },
            DW_OP_not => {
                if (sp < 1) return .empty;
                stack[sp - 1] = ~stack[sp - 1];
            },
            DW_OP_and => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] & stack[sp];
            },
            DW_OP_or => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] | stack[sp];
            },
            DW_OP_xor => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = stack[sp - 1] ^ stack[sp];
            },
            DW_OP_shl => {
                if (sp < 2) return .empty;
                sp -= 1;
                const shift: u6 = @truncate(stack[sp]);
                stack[sp - 1] = stack[sp - 1] << shift;
            },
            DW_OP_shr => {
                if (sp < 2) return .empty;
                sp -= 1;
                const shift: u6 = @truncate(stack[sp]);
                stack[sp - 1] = stack[sp - 1] >> shift;
            },
            DW_OP_shra => {
                if (sp < 2) return .empty;
                sp -= 1;
                const val: i64 = @bitCast(stack[sp - 1]);
                const shift: u6 = @truncate(stack[sp]);
                stack[sp - 1] = @bitCast(val >> shift);
            },
            DW_OP_div => {
                if (sp < 2) return .empty;
                sp -= 1;
                const a: i64 = @bitCast(stack[sp - 1]);
                const b: i64 = @bitCast(stack[sp]);
                if (b == 0) return .empty;
                stack[sp - 1] = @bitCast(@divTrunc(a, b));
            },
            DW_OP_mod => {
                if (sp < 2) return .empty;
                sp -= 1;
                if (stack[sp] == 0) return .empty;
                stack[sp - 1] = stack[sp - 1] % stack[sp];
            },
            DW_OP_eq => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = if (stack[sp - 1] == stack[sp]) 1 else 0;
            },
            DW_OP_ne => {
                if (sp < 2) return .empty;
                sp -= 1;
                stack[sp - 1] = if (stack[sp - 1] != stack[sp]) 1 else 0;
            },
            DW_OP_lt => {
                if (sp < 2) return .empty;
                sp -= 1;
                const a: i64 = @bitCast(stack[sp - 1]);
                const b: i64 = @bitCast(stack[sp]);
                stack[sp - 1] = if (a < b) 1 else 0;
            },
            DW_OP_gt => {
                if (sp < 2) return .empty;
                sp -= 1;
                const a: i64 = @bitCast(stack[sp - 1]);
                const b: i64 = @bitCast(stack[sp]);
                stack[sp - 1] = if (a > b) 1 else 0;
            },
            DW_OP_le => {
                if (sp < 2) return .empty;
                sp -= 1;
                const a: i64 = @bitCast(stack[sp - 1]);
                const b: i64 = @bitCast(stack[sp]);
                stack[sp - 1] = if (a <= b) 1 else 0;
            },
            DW_OP_ge => {
                if (sp < 2) return .empty;
                sp -= 1;
                const a: i64 = @bitCast(stack[sp - 1]);
                const b: i64 = @bitCast(stack[sp]);
                stack[sp - 1] = if (a >= b) 1 else 0;
            },
            DW_OP_skip => {
                if (pos + 2 > expr.len) return .empty;
                const offset: i16 = @bitCast(std.mem.readInt(u16, expr[pos..][0..2], .little));
                pos += 2;
                const new_pos: i64 = @as(i64, @intCast(pos)) + offset;
                if (new_pos < 0 or new_pos > @as(i64, @intCast(expr.len))) return .empty;
                pos = @intCast(new_pos);
            },
            DW_OP_bra => {
                if (sp < 1 or pos + 2 > expr.len) return .empty;
                const offset: i16 = @bitCast(std.mem.readInt(u16, expr[pos..][0..2], .little));
                pos += 2;
                sp -= 1;
                if (stack[sp] != 0) {
                    const new_pos: i64 = @as(i64, @intCast(pos)) + offset;
                    if (new_pos < 0 or new_pos > @as(i64, @intCast(expr.len))) return .empty;
                    pos = @intCast(new_pos);
                }
            },
            DW_OP_bregx => {
                const reg_num = parser.readULEB128(expr, &pos) catch return .empty;
                const offset = parser.readSLEB128(expr, &pos) catch return .empty;
                const reg_val = regs.read(reg_num) orelse return .empty;
                if (sp >= stack.len) return .empty;
                const result = if (offset >= 0)
                    reg_val +% @as(u64, @intCast(offset))
                else
                    reg_val -% @as(u64, @intCast(-offset));
                stack[sp] = result;
                sp += 1;
            },
            DW_OP_deref_size => {
                if (sp < 1 or pos >= expr.len) return .empty;
                const size = expr[pos];
                pos += 1;
                if (mem_reader) |reader| {
                    const val = reader.read(stack[sp - 1], size) orelse return .{ .address = stack[sp - 1] };
                    stack[sp - 1] = val;
                } else {
                    return .{ .address = stack[sp - 1] };
                }
            },
            DW_OP_call_frame_cfa => {
                // CFA (Canonical Frame Address) resolution priority:
                // 1. Real CFA from .eh_frame/.debug_frame (spec-compliant)
                // 2. frame_base if already evaluated (avoids circular dependency)
                // 3. FP+16 heuristic as last resort
                const cfa = context.cfa orelse frame_base orelse blk: {
                    const fp_reg: u64 = if (builtin.cpu.arch == .aarch64) 29 else 6;
                    const fp_val = regs.read(fp_reg) orelse break :blk @as(?u64, null);
                    break :blk fp_val + 16;
                } orelse return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = cfa;
                sp += 1;
            },
            DW_OP_implicit_value => {
                const size = parser.readULEB128(expr, &pos) catch return .empty;
                if (pos + @as(usize, @intCast(size)) > expr.len) return .empty;
                // Read the implicit value (up to 8 bytes)
                var val: u64 = 0;
                const actual_size = @min(size, 8);
                for (0..@intCast(actual_size)) |i| {
                    val |= @as(u64, expr[pos + i]) << @intCast(@as(u6, @truncate(i * 8)));
                }
                pos += @intCast(size);
                return .{ .value = val };
            },
            DW_OP_entry_value, DW_OP_GNU_entry_value => {
                // DW_OP_entry_value: ULEB128 size followed by a sub-expression
                // The sub-expression should be evaluated with register values at function entry.
                const sub_size = parser.readULEB128(expr, &pos) catch return .empty;
                if (pos + @as(usize, @intCast(sub_size)) > expr.len) return .empty;
                const sub_expr = expr[pos..pos + @as(usize, @intCast(sub_size))];
                pos += @intCast(sub_size);
                // Use entry registers if available, fall back to current registers
                const entry_regs = context.entry_regs orelse regs;
                const sub_result = evalLocationImpl(sub_expr, entry_regs, frame_base, mem_reader, context);
                if (sub_result != .empty and sub_result != .implicit_pointer and sub_result != .composite) {
                    const val = switch (sub_result) {
                        .value => |v| v,
                        .address => |a| a,
                        .register => |r| entry_regs.read(@intCast(r)) orelse 0,
                        .empty, .implicit_pointer, .composite => unreachable,
                    };
                    if (sp < stack.len) {
                        stack[sp] = val;
                        sp += 1;
                    }
                }
            },
            DW_OP_stack_value => {
                if (sp < 1) return .empty;
                return .{ .value = stack[sp - 1] };
            },
            DW_OP_piece => {
                const piece_size = parser.readULEB128(expr, &pos) catch return .empty;
                if (piece_count < pieces.len) {
                    if (is_register_result) {
                        pieces[piece_count] = .{
                            .location = .{ .register = last_register },
                            .size_bits = piece_size * 8,
                        };
                        is_register_result = false;
                    } else if (sp > 0) {
                        pieces[piece_count] = .{
                            .location = .{ .address = stack[sp - 1] },
                            .size_bits = piece_size * 8,
                        };
                        sp -= 1;
                    } else {
                        pieces[piece_count] = .{
                            .location = .empty,
                            .size_bits = piece_size * 8,
                        };
                    }
                    piece_count += 1;
                }
            },
            DW_OP_nop => {}, // no-op
            DW_OP_xderef => {
                // Cross-address-space deref: top = address, second = address space ID
                if (sp < 2) return .empty;
                sp -= 1; // pop address (now at stack[sp])
                if (mem_reader) |reader| {
                    const val = reader.read(stack[sp], 8) orelse return .{ .address = stack[sp] };
                    stack[sp - 1] = val;
                } else {
                    return .{ .address = stack[sp] };
                }
            },
            DW_OP_xderef_size => {
                if (sp < 2 or pos >= expr.len) return .empty;
                const size = expr[pos];
                pos += 1;
                sp -= 1; // pop address (now at stack[sp])
                if (mem_reader) |reader| {
                    const val = reader.read(stack[sp], size) orelse return .{ .address = stack[sp] };
                    stack[sp - 1] = val;
                } else {
                    return .{ .address = stack[sp] };
                }
            },
            DW_OP_push_object_address => {
                // Push the object address (used when evaluating DW_AT_data_location)
                if (sp >= stack.len) return .empty;
                stack[sp] = context.object_address orelse 0;
                sp += 1;
            },
            DW_OP_form_tls_address => {
                // TLS address — pop TLS offset, add TLS base to get actual address
                if (sp < 1) return .empty;
                if (context.tls_base) |tls_base| {
                    stack[sp - 1] = stack[sp - 1] +% tls_base;
                }
                // If no TLS base, leave the raw offset on stack as best effort
            },
            DW_OP_call2 => {
                if (pos + 2 > expr.len) return .empty;
                const die_offset: u64 = std.mem.readInt(u16, expr[pos..][0..2], .little);
                pos += 2;
                if (context.debug_info) |di| {
                    if (context.debug_abbrev) |da| {
                        if (extractLocationFromDie(di, da, die_offset)) |loc_expr| {
                            const sub_result = evalLocationImpl(loc_expr, regs, frame_base, mem_reader, context);
                            switch (sub_result) {
                                .value => |v| {
                                    if (sp < stack.len) {
                                        stack[sp] = v;
                                        sp += 1;
                                    }
                                },
                                .address => |a| {
                                    if (sp < stack.len) {
                                        stack[sp] = a;
                                        sp += 1;
                                    }
                                },
                                .register => |r| {
                                    const rv = regs.read(@intCast(r)) orelse return .empty;
                                    if (sp < stack.len) {
                                        stack[sp] = rv;
                                        sp += 1;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            },
            DW_OP_call4 => {
                if (pos + 4 > expr.len) return .empty;
                const die_offset: u64 = std.mem.readInt(u32, expr[pos..][0..4], .little);
                pos += 4;
                if (context.debug_info) |di| {
                    if (context.debug_abbrev) |da| {
                        if (extractLocationFromDie(di, da, die_offset)) |loc_expr| {
                            const sub_result = evalLocationImpl(loc_expr, regs, frame_base, mem_reader, context);
                            switch (sub_result) {
                                .value => |v| {
                                    if (sp < stack.len) {
                                        stack[sp] = v;
                                        sp += 1;
                                    }
                                },
                                .address => |a| {
                                    if (sp < stack.len) {
                                        stack[sp] = a;
                                        sp += 1;
                                    }
                                },
                                .register => |r| {
                                    const rv = regs.read(@intCast(r)) orelse return .empty;
                                    if (sp < stack.len) {
                                        stack[sp] = rv;
                                        sp += 1;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            },
            DW_OP_call_ref => {
                // Offset into .debug_info: 8 bytes for DWARF-64, 4 bytes for DWARF-32
                const ref_size: usize = if (context.is_dwarf64) 8 else 4;
                if (pos + ref_size > expr.len) return .empty;
                const die_offset: u64 = if (context.is_dwarf64)
                    std.mem.readInt(u64, expr[pos..][0..8], .little)
                else
                    @as(u64, std.mem.readInt(u32, expr[pos..][0..4], .little));
                pos += ref_size;
                if (context.debug_info) |di| {
                    if (context.debug_abbrev) |da| {
                        if (extractLocationFromDie(di, da, die_offset)) |loc_expr| {
                            const sub_result = evalLocationImpl(loc_expr, regs, frame_base, mem_reader, context);
                            switch (sub_result) {
                                .value => |v| {
                                    if (sp < stack.len) {
                                        stack[sp] = v;
                                        sp += 1;
                                    }
                                },
                                .address => |a| {
                                    if (sp < stack.len) {
                                        stack[sp] = a;
                                        sp += 1;
                                    }
                                },
                                .register => |r| {
                                    const rv = regs.read(@intCast(r)) orelse return .empty;
                                    if (sp < stack.len) {
                                        stack[sp] = rv;
                                        sp += 1;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            },
            DW_OP_bit_piece => {
                const size_bits = parser.readULEB128(expr, &pos) catch return .empty;
                const offset_bits = parser.readULEB128(expr, &pos) catch return .empty;
                if (piece_count < pieces.len) {
                    if (is_register_result) {
                        pieces[piece_count] = .{
                            .location = .{ .register = last_register },
                            .size_bits = size_bits,
                            .bit_offset = offset_bits,
                        };
                        is_register_result = false;
                    } else if (sp > 0) {
                        pieces[piece_count] = .{
                            .location = .{ .address = stack[sp - 1] },
                            .size_bits = size_bits,
                            .bit_offset = offset_bits,
                        };
                        sp -= 1;
                    } else {
                        pieces[piece_count] = .{
                            .location = .empty,
                            .size_bits = size_bits,
                            .bit_offset = offset_bits,
                        };
                    }
                    piece_count += 1;
                }
            },
            DW_OP_implicit_pointer => {
                // DWARF 5 implicit pointer: DIE offset (format-dependent) + SLEB128 byte offset
                const ref_size: usize = if (context.is_dwarf64) 8 else 4;
                if (pos + ref_size > expr.len) return .empty;
                const die_offset: u64 = if (context.is_dwarf64)
                    std.mem.readInt(u64, expr[pos..][0..8], .little)
                else
                    @as(u64, std.mem.readInt(u32, expr[pos..][0..4], .little));
                pos += ref_size;
                const byte_offset = parser.readSLEB128(expr, &pos) catch return .empty;
                return .{ .implicit_pointer = .{ .die_offset = die_offset, .offset = byte_offset } };
            },
            DW_OP_addrx, DW_OP_constx => {
                // Index into .debug_addr section
                const index = parser.readULEB128(expr, &pos) catch return .empty;
                const addr_data = context.debug_addr orelse return .empty;
                const addr_size: usize = context.address_size;
                const offset = @as(usize, @intCast(context.addr_base)) + index * addr_size;
                if (offset + addr_size > addr_data.len) return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = switch (addr_size) {
                    4 => @as(u64, std.mem.readInt(u32, addr_data[offset..][0..4], .little)),
                    8 => std.mem.readInt(u64, addr_data[offset..][0..8], .little),
                    else => return .empty,
                };
                sp += 1;
            },
            DW_OP_const_type => {
                // Skip ULEB128 type DIE offset + 1-byte size + value bytes
                _ = parser.readULEB128(expr, &pos) catch return .empty;
                if (pos >= expr.len) return .empty;
                const val_size = expr[pos];
                pos += 1;
                if (pos + val_size > expr.len) return .empty;
                // Read value (up to 8 bytes)
                if (sp >= stack.len) return .empty;
                var val: u64 = 0;
                const actual_size = @min(val_size, 8);
                for (0..actual_size) |i| {
                    val |= @as(u64, expr[pos + i]) << @intCast(@as(u6, @truncate(i * 8)));
                }
                stack[sp] = val;
                sp += 1;
                pos += val_size;
            },
            DW_OP_regval_type => {
                // Read register value with type — ULEB128 reg + ULEB128 type offset
                const reg_num = parser.readULEB128(expr, &pos) catch return .empty;
                _ = parser.readULEB128(expr, &pos) catch return .empty; // type offset (ignored)
                const reg_val = regs.read(reg_num) orelse return .empty;
                if (sp >= stack.len) return .empty;
                stack[sp] = reg_val;
                sp += 1;
            },
            DW_OP_deref_type => {
                // Deref with type — 1-byte size + ULEB128 type offset
                if (sp < 1 or pos >= expr.len) return .empty;
                const size = expr[pos];
                pos += 1;
                _ = parser.readULEB128(expr, &pos) catch return .empty; // type offset (ignored)
                if (mem_reader) |reader| {
                    const val = reader.read(stack[sp - 1], size) orelse return .{ .address = stack[sp - 1] };
                    stack[sp - 1] = val;
                } else {
                    return .{ .address = stack[sp - 1] };
                }
            },
            DW_OP_convert, DW_OP_reinterpret => {
                // Skip ULEB128 type offset (identity conversion)
                _ = parser.readULEB128(expr, &pos) catch return .empty;
            },
            else => {
                // Unknown opcode — can't continue
                break;
            },
        }
    }

    // If we collected pieces, return composite result
    if (piece_count > 0) {
        // For single-piece results, return the underlying location directly
        if (piece_count == 1) {
            return switch (pieces[0].location) {
                .address => |a| .{ .address = a },
                .register => |r| .{ .register = r },
                .value => |v| .{ .value = v },
                .empty => .empty,
            };
        }
        // Multi-piece composite — return first piece as fallback
        // (full composite support requires caller cooperation)
        return switch (pieces[0].location) {
            .address => |a| .{ .address = a },
            .register => |r| .{ .register = r },
            .value => |v| .{ .value = v },
            .empty => .empty,
        };
    }

    // If we ended with a deferred register result (no piece followed)
    if (is_register_result) {
        return .{ .register = last_register };
    }

    if (sp > 0) {
        return .{ .address = stack[sp - 1] };
    }
    return .empty;
}

/// Extract a DW_AT_location expression from a DIE at a given offset in .debug_info.
/// Used by DW_OP_call2/call4/call_ref to look up location expressions from other DIEs.
fn extractLocationFromDie(debug_info: []const u8, debug_abbrev: []const u8, die_offset: u64) ?[]const u8 {
    if (die_offset >= debug_info.len) return null;
    var pos: usize = @intCast(die_offset);

    // Read abbreviation code
    const abbrev_code = parser.readULEB128(debug_info, &pos) catch return null;
    if (abbrev_code == 0) return null;

    // Find abbreviation in .debug_abbrev
    var abbrev_pos: usize = 0;
    while (abbrev_pos < debug_abbrev.len) {
        const code = parser.readULEB128(debug_abbrev, &abbrev_pos) catch return null;
        if (code == 0) return null;
        _ = parser.readULEB128(debug_abbrev, &abbrev_pos) catch return null; // tag
        if (abbrev_pos >= debug_abbrev.len) return null;
        abbrev_pos += 1; // has_children

        if (code == abbrev_code) {
            // Parse attributes looking for DW_AT_location (0x02)
            while (abbrev_pos < debug_abbrev.len) {
                const attr = parser.readULEB128(debug_abbrev, &abbrev_pos) catch return null;
                const form = parser.readULEB128(debug_abbrev, &abbrev_pos) catch return null;
                if (attr == 0 and form == 0) break;

                if (attr == 0x02) { // DW_AT_location
                    // Extract the location expression based on form
                    return extractExprFromForm(debug_info, pos, @intCast(form));
                }
                // Skip this attribute's value in debug_info
                skipFormValue(debug_info, &pos, @intCast(form)) catch return null;
            }
            return null;
        }

        // Skip all attributes in this abbreviation
        while (abbrev_pos < debug_abbrev.len) {
            const attr = parser.readULEB128(debug_abbrev, &abbrev_pos) catch return null;
            const form = parser.readULEB128(debug_abbrev, &abbrev_pos) catch return null;
            if (attr == 0 and form == 0) break;
        }
    }
    return null;
}

/// Extract a location expression from a DWARF form at a given position.
fn extractExprFromForm(data: []const u8, pos: usize, form: u8) ?[]const u8 {
    switch (form) {
        0x09 => { // DW_FORM_block — ULEB128 length
            var p = pos;
            const len = parser.readULEB128(data, &p) catch return null;
            const end = p + @as(usize, @intCast(len));
            if (end > data.len) return null;
            return data[p..end];
        },
        0x0a => { // DW_FORM_block1 — 1-byte length
            if (pos >= data.len) return null;
            const len = data[pos];
            if (pos + 1 + len > data.len) return null;
            return data[pos + 1 .. pos + 1 + len];
        },
        0x03 => { // DW_FORM_block2 — 2-byte length
            if (pos + 2 > data.len) return null;
            const len = std.mem.readInt(u16, data[pos..][0..2], .little);
            if (pos + 2 + len > data.len) return null;
            return data[pos + 2 .. pos + 2 + len];
        },
        0x04 => { // DW_FORM_block4 — 4-byte length
            if (pos + 4 > data.len) return null;
            const len = std.mem.readInt(u32, data[pos..][0..4], .little);
            if (pos + 4 + len > data.len) return null;
            return data[pos + 4 .. pos + 4 + len];
        },
        0x18 => { // DW_FORM_exprloc — ULEB128 length
            var p = pos;
            const len = parser.readULEB128(data, &p) catch return null;
            const end = p + @as(usize, @intCast(len));
            if (end > data.len) return null;
            return data[p..end];
        },
        else => return null,
    }
}

/// Skip a DWARF form value in debug_info data.
fn skipFormValue(data: []const u8, pos: *usize, form: u8) !void {
    switch (form) {
        0x01 => pos.* += 8, // DW_FORM_addr (64-bit)
        0x03 => { // DW_FORM_block2 (2-byte length)
            if (pos.* + 2 > data.len) return error.EndOfData;
            const len = std.mem.readInt(u16, data[pos.*..][0..2], .little);
            pos.* += 2 + len;
        },
        0x04 => { // DW_FORM_block4 (4-byte length)
            if (pos.* + 4 > data.len) return error.EndOfData;
            const len = std.mem.readInt(u32, data[pos.*..][0..4], .little);
            pos.* += 4 + @as(usize, @intCast(len));
        },
        0x05 => pos.* += 2, // DW_FORM_data2
        0x06 => pos.* += 4, // DW_FORM_data4
        0x07 => pos.* += 8, // DW_FORM_data8
        0x08 => { // DW_FORM_string (null-terminated)
            while (pos.* < data.len and data[pos.*] != 0) pos.* += 1;
            if (pos.* < data.len) pos.* += 1;
        },
        0x09 => { // DW_FORM_block (ULEB128 length)
            const len = parser.readULEB128(data, pos) catch return error.EndOfData;
            pos.* += @intCast(len);
        },
        0x0a => { // DW_FORM_block1 (1-byte length)
            if (pos.* >= data.len) return error.EndOfData;
            const len = data[pos.*];
            pos.* += 1 + len;
        },
        0x0b => pos.* += 1, // DW_FORM_data1
        0x0c => pos.* += 1, // DW_FORM_flag
        0x0d => { // DW_FORM_sdata (SLEB128)
            _ = parser.readSLEB128(data, pos) catch return error.EndOfData;
        },
        0x0e => pos.* += 4, // DW_FORM_strp (32-bit DWARF)
        0x0f => { // DW_FORM_udata (ULEB128)
            _ = parser.readULEB128(data, pos) catch return error.EndOfData;
        },
        0x10 => pos.* += 4, // DW_FORM_ref_addr (32-bit DWARF)
        0x11 => pos.* += 1, // DW_FORM_ref1
        0x12 => pos.* += 2, // DW_FORM_ref2
        0x13 => pos.* += 4, // DW_FORM_ref4
        0x14 => pos.* += 8, // DW_FORM_ref8
        0x15 => { // DW_FORM_ref_udata (ULEB128)
            _ = parser.readULEB128(data, pos) catch return error.EndOfData;
        },
        0x17 => pos.* += 4, // DW_FORM_sec_offset (32-bit DWARF)
        0x18 => { // DW_FORM_exprloc (ULEB128 length)
            const len = parser.readULEB128(data, pos) catch return error.EndOfData;
            pos.* += @intCast(len);
        },
        0x19 => {}, // DW_FORM_flag_present (zero size)
        0x20 => pos.* += 8, // DW_FORM_ref_sig8
        else => return error.UnknownForm,
    }
}

/// Format a variable value for display.
pub fn formatVariable(
    raw_bytes: []const u8,
    type_name: []const u8,
    encoding: u8,
    byte_size: u8,
    buf: []u8,
) []const u8 {
    if (raw_bytes.len == 0) {
        return formatLiteral(buf, "<optimized out>");
    }

    switch (encoding) {
        DW_ATE_signed, DW_ATE_signed_char => {
            return switch (byte_size) {
                1 => formatTo(buf, "{d}", .{@as(i8, @bitCast(raw_bytes[0]))}),
                2 => blk: {
                    if (raw_bytes.len < 2) break :blk formatLiteral(buf, "<truncated>");
                    const val: i16 = @bitCast(std.mem.readInt(u16, raw_bytes[0..2], .little));
                    break :blk formatTo(buf, "{d}", .{val});
                },
                4 => blk: {
                    if (raw_bytes.len < 4) break :blk formatLiteral(buf, "<truncated>");
                    const val: i32 = @bitCast(std.mem.readInt(u32, raw_bytes[0..4], .little));
                    break :blk formatTo(buf, "{d}", .{val});
                },
                8 => blk: {
                    if (raw_bytes.len < 8) break :blk formatLiteral(buf, "<truncated>");
                    const val: i64 = @bitCast(std.mem.readInt(u64, raw_bytes[0..8], .little));
                    break :blk formatTo(buf, "{d}", .{val});
                },
                else => formatLiteral(buf, "<unsupported size>"),
            };
        },
        DW_ATE_unsigned, DW_ATE_unsigned_char => {
            return switch (byte_size) {
                1 => formatTo(buf, "{d}", .{raw_bytes[0]}),
                2 => blk: {
                    if (raw_bytes.len < 2) break :blk formatLiteral(buf, "<truncated>");
                    const val = std.mem.readInt(u16, raw_bytes[0..2], .little);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                4 => blk: {
                    if (raw_bytes.len < 4) break :blk formatLiteral(buf, "<truncated>");
                    const val = std.mem.readInt(u32, raw_bytes[0..4], .little);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                8 => blk: {
                    if (raw_bytes.len < 8) break :blk formatLiteral(buf, "<truncated>");
                    const val = std.mem.readInt(u64, raw_bytes[0..8], .little);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                else => formatLiteral(buf, "<unsupported size>"),
            };
        },
        DW_ATE_address => {
            if (raw_bytes.len < 8) return formatLiteral(buf, "<truncated>");
            const val = std.mem.readInt(u64, raw_bytes[0..8], .little);
            return formatTo(buf, "0x{x}", .{val});
        },
        DW_ATE_boolean => {
            if (raw_bytes[0] != 0) {
                return formatLiteral(buf, "true");
            } else {
                return formatLiteral(buf, "false");
            }
        },
        DW_ATE_float => {
            return switch (byte_size) {
                4 => blk: {
                    if (raw_bytes.len < 4) break :blk formatLiteral(buf, "<truncated>");
                    const bits = std.mem.readInt(u32, raw_bytes[0..4], .little);
                    const val: f32 = @bitCast(bits);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                8 => blk: {
                    if (raw_bytes.len < 8) break :blk formatLiteral(buf, "<truncated>");
                    const bits = std.mem.readInt(u64, raw_bytes[0..8], .little);
                    const val: f64 = @bitCast(bits);
                    break :blk formatTo(buf, "{d}", .{val});
                },
                else => formatLiteral(buf, "<unsupported float size>"),
            };
        },
        else => {
            _ = type_name;
            return formatTo(buf, "<unknown encoding 0x{x}>", .{encoding});
        },
    }
}

/// Field descriptor for struct formatting.
pub const StructFieldInfo = struct {
    name: []const u8,
    offset: u16,
    encoding: u8,
    byte_size: u8,
};

/// Format a struct value with field names.
/// Output: {field1: val1, field2: val2}
pub fn formatStruct(
    raw_bytes: []const u8,
    fields: []const StructFieldInfo,
    buf: []u8,
) []const u8 {
    if (fields.len == 0) return formatLiteral(buf, "{}");

    var pos: usize = 0;
    if (pos < buf.len) {
        buf[pos] = '{';
        pos += 1;
    }

    for (fields, 0..) |field, i| {
        if (i > 0) {
            const sep = ", ";
            if (pos + sep.len <= buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
            }
        }

        // Write field name
        if (pos + field.name.len <= buf.len) {
            @memcpy(buf[pos..][0..field.name.len], field.name);
            pos += field.name.len;
        }
        if (pos + 2 <= buf.len) {
            buf[pos] = ':';
            buf[pos + 1] = ' ';
            pos += 2;
        }

        // Format field value
        const field_start = field.offset;
        const field_end = field_start + field.byte_size;
        if (field_end <= raw_bytes.len) {
            var field_buf: [64]u8 = undefined;
            const val_str = formatVariable(
                raw_bytes[field_start..field_end],
                "",
                field.encoding,
                field.byte_size,
                &field_buf,
            );
            if (pos + val_str.len <= buf.len) {
                @memcpy(buf[pos..][0..val_str.len], val_str);
                pos += val_str.len;
            }
        } else {
            const trunc = "<truncated>";
            if (pos + trunc.len <= buf.len) {
                @memcpy(buf[pos..][0..trunc.len], trunc);
                pos += trunc.len;
            }
        }
    }

    if (pos < buf.len) {
        buf[pos] = '}';
        pos += 1;
    }

    return buf[0..pos];
}

/// Format an array value with elements.
/// Output: [val1, val2, val3]
pub fn formatArray(
    raw_bytes: []const u8,
    element_encoding: u8,
    element_byte_size: u8,
    count: u32,
    buf: []u8,
) []const u8 {
    if (count == 0) return formatLiteral(buf, "[]");

    var pos: usize = 0;
    if (pos < buf.len) {
        buf[pos] = '[';
        pos += 1;
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i > 0) {
            const sep = ", ";
            if (pos + sep.len <= buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
            }
        }

        const elem_start = @as(usize, i) * element_byte_size;
        const elem_end = elem_start + element_byte_size;
        if (elem_end <= raw_bytes.len) {
            var elem_buf: [64]u8 = undefined;
            const val_str = formatVariable(
                raw_bytes[elem_start..elem_end],
                "",
                element_encoding,
                element_byte_size,
                &elem_buf,
            );
            if (pos + val_str.len <= buf.len) {
                @memcpy(buf[pos..][0..val_str.len], val_str);
                pos += val_str.len;
            }
        } else {
            const trunc = "...";
            if (pos + trunc.len <= buf.len) {
                @memcpy(buf[pos..][0..trunc.len], trunc);
                pos += trunc.len;
            }
            break;
        }
    }

    if (pos < buf.len) {
        buf[pos] = ']';
        pos += 1;
    }

    return buf[0..pos];
}

/// Inspect all local variables in the current frame.
/// Uses parsed variable info, register state, and optional memory reader
/// to evaluate locations and read values.
pub fn inspectLocals(
    variables: []const parser.VariableInfo,
    regs: RegisterProvider,
    frame_base: ?u64,
    mem_reader: ?MemoryReader,
    allocator: std.mem.Allocator,
) ![]VariableValue {
    var results: std.ArrayListUnmanaged(VariableValue) = .empty;
    errdefer {
        for (results.items) |v| {
            allocator.free(v.value_str);
            allocator.free(v.type_str);
        }
        results.deinit(allocator);
    }

    for (variables) |v| {
        if (v.location_expr.len == 0) continue;

        const loc = evalLocationWithMemory(v.location_expr, regs, frame_base, mem_reader);

        {
            const df = std.fs.cwd().createFile("/tmp/cog-dwarf-debug.log", .{ .truncate = false }) catch null;
            if (df) |dfile| {
                defer dfile.close();
                dfile.seekFromEnd(0) catch {};
                var lbuf: [1024]u8 = undefined;
                var pos: usize = 0;
                const loc_type: []const u8 = switch (loc) {
                    .address => "address",
                    .register => "register",
                    .value => "value",
                    .empty => "empty",
                    .implicit_pointer => "implicit_pointer",
                    .composite => "composite",
                };
                pos += (std.fmt.bufPrint(lbuf[pos..], "inspectVars: name={s} loc_expr_len={} loc_type={s}", .{
                    v.name, v.location_expr.len, loc_type,
                }) catch "").len;
                pos += (switch (loc) {
                    .address => |a| std.fmt.bufPrint(lbuf[pos..], " addr=0x{x}", .{a}) catch "",
                    .register => |r| std.fmt.bufPrint(lbuf[pos..], " reg={}", .{r}) catch "",
                    .value => |val| std.fmt.bufPrint(lbuf[pos..], " val={}", .{val}) catch "",
                    else => @as([]const u8, ""),
                }).len;
                if (frame_base) |fb| {
                    pos += (std.fmt.bufPrint(lbuf[pos..], " frame_base=0x{x} loc_bytes=", .{fb}) catch "").len;
                } else {
                    pos += (std.fmt.bufPrint(lbuf[pos..], " frame_base=null loc_bytes=", .{}) catch "").len;
                }
                for (v.location_expr) |b| {
                    pos += (std.fmt.bufPrint(lbuf[pos..], "{x:0>2}", .{b}) catch "").len;
                }
                if (pos < lbuf.len) {
                    lbuf[pos] = '\n';
                    pos += 1;
                }
                dfile.writeAll(lbuf[0..pos]) catch {};
            }
        }

        var value_str: []const u8 = "";
        switch (loc) {
            .value => |val| {
                // Stack value — format directly
                var raw: [8]u8 = undefined;
                std.mem.writeInt(u64, &raw, val, .little);
                var fmt_buf: [64]u8 = undefined;
                const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                const formatted = formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                value_str = try allocator.dupe(u8, formatted);
            },
            .address => |addr| {
                // Address — try to read from memory
                if (mem_reader) |reader| {
                    const size: usize = if (v.type_byte_size > 0) v.type_byte_size else 8;
                    var raw: [8]u8 = undefined;
                    const val = reader.read(addr, size) orelse {
                        value_str = try allocator.dupe(u8, "<unreadable>");
                        break;
                    };
                    std.mem.writeInt(u64, &raw, val, .little);
                    var fmt_buf: [64]u8 = undefined;
                    const formatted = formatVariable(raw[0..size], v.type_name, v.type_encoding, @intCast(size), &fmt_buf);
                    value_str = try allocator.dupe(u8, formatted);
                } else {
                    var fmt_buf: [32]u8 = undefined;
                    const addr_str = formatTo(&fmt_buf, "0x{x}", .{addr});
                    value_str = try allocator.dupe(u8, addr_str);
                }
            },
            .register => |reg| {
                if (regs.read(reg)) |val| {
                    var raw: [8]u8 = undefined;
                    std.mem.writeInt(u64, &raw, val, .little);
                    var fmt_buf: [64]u8 = undefined;
                    const effective_size = if (v.type_byte_size > 0) v.type_byte_size else 8;
                    const formatted = formatVariable(raw[0..effective_size], v.type_name, v.type_encoding, effective_size, &fmt_buf);
                    value_str = try allocator.dupe(u8, formatted);
                } else {
                    value_str = try allocator.dupe(u8, "<unavailable>");
                }
            },
            .implicit_pointer => {
                value_str = try allocator.dupe(u8, "<implicit pointer>");
            },
            .composite => {
                value_str = try allocator.dupe(u8, "<composite>");
            },
            .empty => {
                value_str = try allocator.dupe(u8, "<optimized out>");
            },
        }

        const type_str = try allocator.dupe(u8, v.type_name);

        try results.append(allocator, .{
            .name = v.name,
            .value_str = value_str,
            .type_str = type_str,
        });
    }

    return try results.toOwnedSlice(allocator);
}

pub fn freeInspectResults(results: []VariableValue, allocator: std.mem.Allocator) void {
    for (results) |v| {
        allocator.free(v.value_str);
        allocator.free(v.type_str);
    }
    allocator.free(results);
}

fn formatTo(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    const written = std.fmt.bufPrint(buf, fmt, args) catch return "<format error>";
    return written;
}

fn formatLiteral(buf: []u8, comptime str: []const u8) []const u8 {
    if (str.len > buf.len) return str[0..buf.len];
    @memcpy(buf[0..str.len], str);
    return buf[0..str.len];
}

// ── Tests ───────────────────────────────────────────────────────────────

const MockRegisters = struct {
    values: [32]u64 = [_]u64{0} ** 32,

    fn readReg(ctx: *anyopaque, reg: u64) ?u64 {
        const self: *MockRegisters = @ptrCast(@alignCast(ctx));
        if (reg < 32) return self.values[@intCast(reg)];
        return null;
    }

    fn provider(self: *MockRegisters) RegisterProvider {
        return .{
            .ptr = @ptrCast(self),
            .readFn = readReg,
        };
    }
};

test "evalLocation handles DW_OP_fbreg (frame base relative)" {
    // DW_OP_fbreg with offset -8
    const expr = [_]u8{ DW_OP_fbreg, 0x78 }; // -8 in SLEB128
    var regs = MockRegisters{};

    const result = evalLocation(&expr, regs.provider(), 0x7FFF0100);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x7FFF00F8), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_reg (register value)" {
    // DW_OP_reg0 = register 0
    const expr = [_]u8{DW_OP_reg0};
    var regs = MockRegisters{};
    regs.values[0] = 42;

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .register => |reg| try std.testing.expectEqual(@as(u64, 0), reg),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_addr (absolute address)" {
    // DW_OP_addr followed by 8-byte address
    var expr: [9]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0xDEADBEEF, .little);

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0xDEADBEEF), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_plus_uconst" {
    // Push address, then add offset
    var expr: [11]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0x1000, .little);
    expr[9] = DW_OP_plus_uconst;
    expr[10] = 0x10; // offset 16

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x1010), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_deref" {
    var expr: [10]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0x2000, .little);
    expr[9] = DW_OP_deref;

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    // Deref returns the address to be dereferenced
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x2000), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles DW_OP_breg with offset" {
    // DW_OP_breg6 (rbp on x86_64) with offset -16
    const expr = [_]u8{ DW_OP_breg0 + 6, 0x70 }; // -16 in SLEB128
    var regs = MockRegisters{};
    regs.values[6] = 0x7FFF0200;

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x7FFF01F0), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation handles stack_value" {
    // Push constant, mark as stack value
    const expr = [_]u8{ DW_OP_constu, 42, DW_OP_stack_value };
    var regs = MockRegisters{};

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .value => |val| try std.testing.expectEqual(@as(u64, 42), val),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocation returns empty for empty expression" {
    const expr = [_]u8{};
    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .empty => {},
        else => return error.TestUnexpectedResult,
    }
}

test "formatVariable formats integer correctly" {
    var raw = [_]u8{ 42, 0, 0, 0 };
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int", DW_ATE_signed, 4, &buf);
    try std.testing.expectEqualStrings("42", result);
}

test "formatVariable formats negative integer" {
    // -1 as i32 = 0xFFFFFFFF
    var raw = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int", DW_ATE_signed, 4, &buf);
    try std.testing.expectEqualStrings("-1", result);
}

test "formatVariable formats pointer as hex address" {
    var raw: [8]u8 = undefined;
    std.mem.writeInt(u64, &raw, 0xDEADBEEF, .little);
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int*", DW_ATE_address, 8, &buf);
    try std.testing.expectEqualStrings("0xdeadbeef", result);
}

test "formatVariable formats boolean" {
    var raw_true = [_]u8{1};
    var raw_false = [_]u8{0};
    var buf: [64]u8 = undefined;

    const true_str = formatVariable(&raw_true, "bool", DW_ATE_boolean, 1, &buf);
    try std.testing.expectEqualStrings("true", true_str);

    const false_str = formatVariable(&raw_false, "bool", DW_ATE_boolean, 1, &buf);
    try std.testing.expectEqualStrings("false", false_str);
}

test "formatVariable formats unsigned integer" {
    var raw = [_]u8{ 255, 0, 0, 0 };
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "unsigned int", DW_ATE_unsigned, 4, &buf);
    try std.testing.expectEqualStrings("255", result);
}

test "formatVariable formats empty bytes as optimized out" {
    const raw = [_]u8{};
    var buf: [64]u8 = undefined;
    const result = formatVariable(&raw, "int", DW_ATE_signed, 4, &buf);
    try std.testing.expectEqualStrings("<optimized out>", result);
}

test "formatVariable formats struct with field names" {
    // Struct with two i32 fields: {x: 42, y: 10}
    var raw: [8]u8 = undefined;
    std.mem.writeInt(i32, raw[0..4], 42, .little);
    std.mem.writeInt(i32, raw[4..8], 10, .little);

    const fields = [_]StructFieldInfo{
        .{ .name = "x", .offset = 0, .encoding = DW_ATE_signed, .byte_size = 4 },
        .{ .name = "y", .offset = 4, .encoding = DW_ATE_signed, .byte_size = 4 },
    };

    var buf: [128]u8 = undefined;
    const result = formatStruct(&raw, &fields, &buf);
    try std.testing.expectEqualStrings("{x: 42, y: 10}", result);
}

test "formatVariable formats array with elements" {
    // Array of 3 i32: [1, 2, 3]
    var raw: [12]u8 = undefined;
    std.mem.writeInt(i32, raw[0..4], 1, .little);
    std.mem.writeInt(i32, raw[4..8], 2, .little);
    std.mem.writeInt(i32, raw[8..12], 3, .little);

    var buf: [128]u8 = undefined;
    const result = formatArray(&raw, DW_ATE_signed, 4, 3, &buf);
    try std.testing.expectEqualStrings("[1, 2, 3]", result);
}

const MockMemory = struct {
    data: std.AutoHashMap(u64, u64),

    fn init(allocator: std.mem.Allocator) MockMemory {
        return .{ .data = std.AutoHashMap(u64, u64).init(allocator) };
    }

    fn deinit(self: *MockMemory) void {
        self.data.deinit();
    }

    fn readMem(ctx: *anyopaque, addr: u64, size: usize) ?u64 {
        _ = size;
        const self: *MockMemory = @ptrCast(@alignCast(ctx));
        return self.data.get(addr);
    }

    fn reader(self: *MockMemory) MemoryReader {
        return .{
            .ptr = @ptrCast(self),
            .readFn = readMem,
        };
    }
};

test "inspectLocals returns all variables in current frame" {
    // Set up variables with stack_value location expressions
    const var_x = parser.VariableInfo{
        .name = "x",
        .location_expr = &[_]u8{ DW_OP_constu, 42, DW_OP_stack_value },
        .type_encoding = DW_ATE_signed,
        .type_byte_size = 4,
        .type_name = "int",
    };
    const var_y = parser.VariableInfo{
        .name = "y",
        .location_expr = &[_]u8{ DW_OP_constu, 10, DW_OP_stack_value },
        .type_encoding = DW_ATE_signed,
        .type_byte_size = 4,
        .type_name = "int",
    };
    const vars = [_]parser.VariableInfo{ var_x, var_y };

    var regs = MockRegisters{};
    const results = try inspectLocals(&vars, regs.provider(), null, null, std.testing.allocator);
    defer freeInspectResults(results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("x", results[0].name);
    try std.testing.expectEqualStrings("42", results[0].value_str);
    try std.testing.expectEqualStrings("int", results[0].type_str);
    try std.testing.expectEqualStrings("y", results[1].name);
    try std.testing.expectEqualStrings("10", results[1].value_str);
}

test "inspectLocals reads correct integer value from memory" {
    // Variable at frame_base - 8, value is 99
    const var_x = parser.VariableInfo{
        .name = "x",
        .location_expr = &[_]u8{ DW_OP_fbreg, 0x78 }, // fbreg offset -8
        .type_encoding = DW_ATE_signed,
        .type_byte_size = 4,
        .type_name = "int",
    };
    const vars = [_]parser.VariableInfo{var_x};

    var regs = MockRegisters{};
    var mem = MockMemory.init(std.testing.allocator);
    defer mem.deinit();
    // Frame base is 0x1000, variable at 0x1000 - 8 = 0xFF8
    try mem.data.put(0xFF8, 99);

    const results = try inspectLocals(&vars, regs.provider(), 0x1000, mem.reader(), std.testing.allocator);
    defer freeInspectResults(results, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("x", results[0].name);
    try std.testing.expectEqualStrings("99", results[0].value_str);
}

test "evalLocationWithMemory handles DW_OP_deref with reader" {
    var expr: [10]u8 = undefined;
    expr[0] = DW_OP_addr;
    std.mem.writeInt(u64, expr[1..9], 0x2000, .little);
    expr[9] = DW_OP_deref;

    var regs = MockRegisters{};
    var mem = MockMemory.init(std.testing.allocator);
    defer mem.deinit();
    try mem.data.put(0x2000, 0xCAFEBABE);

    const result = evalLocationWithMemory(&expr, regs.provider(), null, mem.reader());
    switch (result) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0xCAFEBABE), addr),
        else => return error.TestUnexpectedResult,
    }
}

test "DW_OP_nop is a no-op" {
    // nop + constu 42 + stack_value => value 42
    const expr = [_]u8{ DW_OP_nop, DW_OP_constu, 42, DW_OP_stack_value };
    var regs = MockRegisters{};

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .value => |val| try std.testing.expectEqual(@as(u64, 42), val),
        else => return error.TestUnexpectedResult,
    }
}

test "DW_OP_implicit_pointer returns correct result" {
    // DW_OP_implicit_pointer: 4-byte DIE offset (0x100) + SLEB128 byte offset (4) [DWARF-32]
    var expr: [6]u8 = undefined;
    expr[0] = DW_OP_implicit_pointer;
    std.mem.writeInt(u32, expr[1..5], 0x100, .little);
    expr[5] = 0x04; // SLEB128 encoding of 4

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .implicit_pointer => |ip| {
            try std.testing.expectEqual(@as(u64, 0x100), ip.die_offset);
            try std.testing.expectEqual(@as(i64, 4), ip.offset);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "DW_OP_const_type pushes value to stack" {
    // DW_OP_const_type: ULEB128 type offset (0x01) + 1-byte size (4) + 4 value bytes + stack_value
    const expr = [_]u8{
        DW_OP_const_type,
        0x01, // type DIE offset (ULEB128)
        4, // size = 4 bytes
        0x2A, 0x00, 0x00, 0x00, // value = 42 little-endian
        DW_OP_stack_value,
    };

    var regs = MockRegisters{};
    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .value => |val| try std.testing.expectEqual(@as(u64, 42), val),
        else => return error.TestUnexpectedResult,
    }
}

test "DW_OP_convert is skipped (identity conversion)" {
    // constu 42 + convert (type offset 0x01) + stack_value => value 42
    const expr = [_]u8{ DW_OP_constu, 42, DW_OP_convert, 0x01, DW_OP_stack_value };
    var regs = MockRegisters{};

    const result = evalLocation(&expr, regs.provider(), null);
    switch (result) {
        .value => |val| try std.testing.expectEqual(@as(u64, 42), val),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocationListDwarf5 with DW_LLE_base_addressx" {
    // Build mock debug_addr: address at index 0 = 0x1000
    var debug_addr_data: [16]u8 = undefined;
    std.mem.writeInt(u64, debug_addr_data[0..8], 0x1000, .little); // index 0
    std.mem.writeInt(u64, debug_addr_data[8..16], 0x2000, .little); // index 1

    // Build loclists data:
    // DW_LLE_base_addressx(index=0) + DW_LLE_offset_pair(begin=0, end=0x100, expr=[DW_OP_constu, 99, DW_OP_stack_value])
    const loclists = [_]u8{
        DW_LLE_base_addressx,
        0x00, // ULEB128 index = 0
        DW_LLE_offset_pair,
        0x00, // ULEB128 begin offset = 0
        0x80, 0x02, // ULEB128 end offset = 256 (0x100)
        0x03, // ULEB128 expr_len = 3
        DW_OP_constu, 99, DW_OP_stack_value,
        DW_LLE_end_of_list,
    };

    // PC = 0x1050 should be in range [0x1000, 0x1100)
    const result = evalLocationListDwarf5(&loclists, 0, 0x1050, 0, &debug_addr_data, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.len);
    try std.testing.expectEqual(DW_OP_constu, result.?[0]);
}

test "evalLocationListDwarf5 with DW_LLE_startx_length" {
    // Build mock debug_addr: address at index 0 = 0x5000
    var debug_addr_data: [8]u8 = undefined;
    std.mem.writeInt(u64, debug_addr_data[0..8], 0x5000, .little); // index 0

    // Build loclists data:
    // DW_LLE_startx_length(start_idx=0, length=0x100, expr=[DW_OP_lit0, DW_OP_stack_value])
    const loclists = [_]u8{
        DW_LLE_startx_length,
        0x00, // ULEB128 start_idx = 0
        0x80, 0x02, // ULEB128 length = 256 (0x100)
        0x02, // ULEB128 expr_len = 2
        DW_OP_lit0, DW_OP_stack_value,
        DW_LLE_end_of_list,
    };

    // PC = 0x5050 should be in range [0x5000, 0x5100)
    const result = evalLocationListDwarf5(&loclists, 0, 0x5050, 0, &debug_addr_data, 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.len);
    try std.testing.expectEqual(DW_OP_lit0, result.?[0]);

    // PC = 0x5200 should be outside range
    const result2 = evalLocationListDwarf5(&loclists, 0, 0x5200, 0, &debug_addr_data, 0);
    try std.testing.expect(result2 == null);
}

test "evalLocationList returns correct expression for matching PC range" {
    // Build a DWARF 4 .debug_loc location list with two ranges:
    //   Range 1: [0x1000, 0x1100) -> DW_OP_breg6(-8) (variable at rbp-8)
    //   Range 2: [0x1100, 0x1200) -> DW_OP_reg0 (variable in rax)
    //   End of list
    var loc_data: [55]u8 = undefined;
    var off: usize = 0;

    // Entry 1: begin=0x1000, end=0x1100, expr=[DW_OP_breg6, -8 SLEB128]
    std.mem.writeInt(u64, loc_data[off..][0..8], 0x1000, .little);
    off += 8;
    std.mem.writeInt(u64, loc_data[off..][0..8], 0x1100, .little);
    off += 8;
    std.mem.writeInt(u16, loc_data[off..][0..2], 2, .little); // expr_len = 2
    off += 2;
    loc_data[off] = DW_OP_breg0 + 6; // DW_OP_breg6
    off += 1;
    loc_data[off] = 0x78; // SLEB128(-8)
    off += 1;

    // Entry 2: begin=0x1100, end=0x1200, expr=[DW_OP_reg0]
    std.mem.writeInt(u64, loc_data[off..][0..8], 0x1100, .little);
    off += 8;
    std.mem.writeInt(u64, loc_data[off..][0..8], 0x1200, .little);
    off += 8;
    std.mem.writeInt(u16, loc_data[off..][0..2], 1, .little); // expr_len = 1
    off += 2;
    loc_data[off] = DW_OP_reg0;
    off += 1;

    // End of list: begin=0, end=0
    std.mem.writeInt(u64, loc_data[off..][0..8], 0, .little);
    off += 8;
    std.mem.writeInt(u64, loc_data[off..][0..8], 0, .little);

    // Test PC in first range returns breg6(-8) expression
    const result1 = evalLocationList(&loc_data, 0, 0x1050, 0);
    try std.testing.expect(result1 != null);
    try std.testing.expectEqual(@as(usize, 2), result1.?.len);
    try std.testing.expectEqual(DW_OP_breg0 + 6, result1.?[0]);

    // Verify the expression evaluates correctly
    var regs = MockRegisters{};
    regs.values[6] = 0x7FFF0200; // rbp
    const loc_result1 = evalLocation(result1.?, regs.provider(), null);
    switch (loc_result1) {
        .address => |addr| try std.testing.expectEqual(@as(u64, 0x7FFF01F8), addr),
        else => return error.TestUnexpectedResult,
    }

    // Test PC in second range returns reg0 expression
    const result2 = evalLocationList(&loc_data, 0, 0x1150, 0);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 1), result2.?.len);
    try std.testing.expectEqual(DW_OP_reg0, result2.?[0]);

    // Verify it evaluates as a register location
    const loc_result2 = evalLocation(result2.?, regs.provider(), null);
    switch (loc_result2) {
        .register => |reg| try std.testing.expectEqual(@as(u64, 0), reg),
        else => return error.TestUnexpectedResult,
    }
}

test "evalLocationList returns null for PC outside all ranges" {
    // Build a DWARF 4 .debug_loc location list with one range:
    //   Range: [0x2000, 0x2100) -> DW_OP_constu(42), DW_OP_stack_value
    //   End of list
    var loc_data: [37]u8 = undefined;
    var off: usize = 0;

    // Entry: begin=0x2000, end=0x2100, expr=[DW_OP_constu, 42, DW_OP_stack_value]
    std.mem.writeInt(u64, loc_data[off..][0..8], 0x2000, .little);
    off += 8;
    std.mem.writeInt(u64, loc_data[off..][0..8], 0x2100, .little);
    off += 8;
    std.mem.writeInt(u16, loc_data[off..][0..2], 3, .little); // expr_len = 3
    off += 2;
    loc_data[off] = DW_OP_constu;
    off += 1;
    loc_data[off] = 42;
    off += 1;
    loc_data[off] = DW_OP_stack_value;
    off += 1;

    // End of list: begin=0, end=0
    std.mem.writeInt(u64, loc_data[off..][0..8], 0, .little);
    off += 8;
    std.mem.writeInt(u64, loc_data[off..][0..8], 0, .little);

    // PC before range
    const result1 = evalLocationList(&loc_data, 0, 0x1FFF, 0);
    try std.testing.expect(result1 == null);

    // PC after range
    const result2 = evalLocationList(&loc_data, 0, 0x2100, 0);
    try std.testing.expect(result2 == null);

    // PC way beyond range
    const result3 = evalLocationList(&loc_data, 0, 0x5000, 0);
    try std.testing.expect(result3 == null);

    // But PC within range should succeed
    const result_ok = evalLocationList(&loc_data, 0, 0x2050, 0);
    try std.testing.expect(result_ok != null);
    try std.testing.expectEqual(@as(usize, 3), result_ok.?.len);

    // Verify it evaluates to value 42
    var regs = MockRegisters{};
    const loc_result = evalLocation(result_ok.?, regs.provider(), null);
    switch (loc_result) {
        .value => |val| try std.testing.expectEqual(@as(u64, 42), val),
        else => return error.TestUnexpectedResult,
    }
}
