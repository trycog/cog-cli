const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");
const process_mod = @import("process.zig");
const types = @import("../types.zig");

// ── Software Breakpoint Management ─────────────────────────────────────

const is_arm = builtin.cpu.arch == .aarch64;
// ARM64: BRK #0 = 0xD4200000 (4 bytes little-endian)
// x86_64: INT3 = 0xCC (1 byte)
pub const bp_size: usize = if (is_arm) 4 else 1;
const brk_bytes = [4]u8{ 0x00, 0x00, 0x20, 0xD4 };
const int3_bytes = [1]u8{0xCC};
pub const trap_instruction: []const u8 = if (is_arm) &brk_bytes else &int3_bytes;

pub const Breakpoint = struct {
    id: u32,
    address: u64,
    file: []const u8,
    line: u32,
    column: ?u32 = null,
    original_bytes: [bp_size]u8,
    enabled: bool,
    hit_count: u32,
    condition: ?[]const u8,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
    is_temporary: bool = false,
};

pub const BreakpointManager = struct {
    breakpoints: std.ArrayListUnmanaged(Breakpoint),
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BreakpointManager {
        return .{
            .breakpoints = .empty,
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BreakpointManager) void {
        for (self.breakpoints.items) |bp| {
            if (bp.file.len > 0) self.allocator.free(bp.file);
        }
        self.breakpoints.deinit(self.allocator);
    }

    /// Resolve a file:line to an address using DWARF line entries and set a breakpoint.
    pub fn resolveAndSet(
        self: *BreakpointManager,
        file: []const u8,
        line: u32,
        line_entries: []const parser.LineEntry,
        file_entries: []const parser.FileEntry,
        condition: ?[]const u8,
    ) !Breakpoint {
        return self.resolveAndSetEx(file, line, line_entries, file_entries, condition, null, null);
    }

    /// Resolve a file:line:column to an address using DWARF line entries and set a breakpoint.
    pub fn resolveAndSetColumn(
        self: *BreakpointManager,
        file: []const u8,
        line: u32,
        column: ?u32,
        line_entries: []const parser.LineEntry,
        file_entries: []const parser.FileEntry,
        condition: ?[]const u8,
        hit_condition: ?[]const u8,
        log_message: ?[]const u8,
    ) !Breakpoint {
        return self.resolveAndSetExInternal(file, line, column, line_entries, file_entries, condition, hit_condition, log_message);
    }

    /// Resolve a file:line to an address with extended options.
    pub fn resolveAndSetEx(
        self: *BreakpointManager,
        file: []const u8,
        line: u32,
        line_entries: []const parser.LineEntry,
        file_entries: []const parser.FileEntry,
        condition: ?[]const u8,
        hit_condition: ?[]const u8,
        log_message: ?[]const u8,
    ) !Breakpoint {
        return self.resolveAndSetExInternal(file, line, null, line_entries, file_entries, condition, hit_condition, log_message);
    }

    /// Internal resolver that handles both line-only and line+column matching.
    fn resolveAndSetExInternal(
        self: *BreakpointManager,
        file: []const u8,
        line: u32,
        column: ?u32,
        line_entries: []const parser.LineEntry,
        file_entries: []const parser.FileEntry,
        condition: ?[]const u8,
        hit_condition: ?[]const u8,
        log_message: ?[]const u8,
    ) !Breakpoint {
        // Find the best matching line entry
        var best_addr: ?u64 = null;
        var best_line: u32 = 0;
        var best_col_distance: u32 = std.math.maxInt(u32);
        var best_match_quality: u8 = 0;

        for (line_entries) |entry| {
            if (entry.end_sequence) continue;
            if (!entry.is_stmt) continue;

            // File matching: compute quality and skip non-matches.
            // Prefer higher quality matches (3=exact, 2=suffix, 1=basename).
            var quality: u8 = 1; // default when no file entries to check
            if (file_entries.len > 0 and file.len > 0) {
                const entry_file = getEntryFileName(file_entries, entry.file_index);
                quality = fileMatchQuality(file, entry_file);
                if (quality == 0) continue;
            }

            if (entry.line == line) {
                if (column) |requested_col| {
                    // Column matching: prefer exact column match, otherwise closest column
                    const col_distance = if (entry.column >= requested_col)
                        entry.column - requested_col
                    else
                        requested_col - entry.column;

                    if (quality > best_match_quality or best_addr == null or best_line != line or (quality == best_match_quality and col_distance < best_col_distance)) {
                        best_addr = entry.address;
                        best_line = entry.line;
                        best_col_distance = col_distance;
                        best_match_quality = quality;
                    }
                } else {
                    // No column requested: take best quality exact line match.
                    // Also prefer an exact line match over a previous fallback (nearest line >= requested).
                    if (quality > best_match_quality or best_addr == null or best_line != line) {
                        best_addr = entry.address;
                        best_line = entry.line;
                        best_match_quality = quality;
                    }
                    // Only break early on exact path match (quality 3)
                    if (quality == 3) break;
                }
            } else if (entry.line >= line) {
                // Also accept the nearest line at or after the requested line
                // but only if we haven't found an exact line match with equal or better quality
                if (quality >= best_match_quality and best_line != line and (best_addr == null or entry.line < best_line)) {
                    best_addr = entry.address;
                    best_line = entry.line;
                    best_match_quality = quality;
                }
            }
        }

        const address = best_addr orelse return error.NoAddressForLine;

        const owned_file = try self.allocator.dupe(u8, file);
        errdefer self.allocator.free(owned_file);

        const bp = Breakpoint{
            .id = self.next_id,
            .address = address,
            .file = owned_file,
            .line = best_line,
            .column = column,
            .original_bytes = std.mem.zeroes([bp_size]u8),
            .enabled = true,
            .hit_count = 0,
            .condition = condition,
            .hit_condition = hit_condition,
            .log_message = log_message,
        };
        self.next_id += 1;
        try self.breakpoints.append(self.allocator, bp);
        return bp;
    }

    /// Set a temporary breakpoint at a raw address that auto-removes after first hit.
    pub fn setTemporary(self: *BreakpointManager, address: u64) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        try self.breakpoints.append(self.allocator, .{
            .id = id,
            .address = address,
            .file = "",
            .line = 0,
            .original_bytes = std.mem.zeroes([bp_size]u8),
            .enabled = true,
            .hit_count = 0,
            .condition = null,
            .is_temporary = true,
        });

        return id;
    }

    /// Clean up any temporary breakpoints that have been hit (hit_count > 0).
    pub fn cleanupTemporary(self: *BreakpointManager, process: *process_mod.ProcessControl) void {
        var i: usize = 0;
        while (i < self.breakpoints.items.len) {
            const bp = &self.breakpoints.items[i];
            if (bp.is_temporary and bp.hit_count > 0) {
                // Restore original bytes
                if (bp.enabled) {
                    process.writeMemory(bp.address, &bp.original_bytes) catch {};
                }
                _ = self.breakpoints.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Set a breakpoint at a raw address (for testing without DWARF data).
    pub fn setAtAddress(
        self: *BreakpointManager,
        address: u64,
        file: []const u8,
        line: u32,
    ) !u32 {
        return self.setAtAddressEx(address, file, line, null);
    }

    /// Set a breakpoint at a raw address with optional condition.
    pub fn setAtAddressEx(
        self: *BreakpointManager,
        address: u64,
        file: []const u8,
        line: u32,
        condition: ?[]const u8,
    ) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        const owned_file = try self.allocator.dupe(u8, file);
        errdefer self.allocator.free(owned_file);

        try self.breakpoints.append(self.allocator, .{
            .id = id,
            .address = address,
            .file = owned_file,
            .line = line,
            .original_bytes = std.mem.zeroes([bp_size]u8),
            .enabled = true,
            .hit_count = 0,
            .condition = condition,
        });

        return id;
    }

    /// Set a breakpoint at an instruction address from an InstructionBreakpoint.
    /// Parses the instruction_reference as a hex address and applies the optional offset.
    pub fn setInstructionBreakpoint(self: *BreakpointManager, bp: types.InstructionBreakpoint) !u32 {
        // Parse the instruction reference as a hex address (with or without "0x" prefix)
        const ref = bp.instruction_reference;
        const hex_str = if (ref.len > 2 and ref[0] == '0' and (ref[1] == 'x' or ref[1] == 'X'))
            ref[2..]
        else
            ref;

        const base_addr = std.fmt.parseInt(u64, hex_str, 16) catch return error.InvalidInstructionReference;

        // Apply offset if provided
        const address: u64 = if (bp.offset) |offset| blk: {
            if (offset >= 0) {
                break :blk base_addr +% @as(u64, @intCast(offset));
            } else {
                break :blk base_addr -% @as(u64, @intCast(-offset));
            }
        } else base_addr;

        const id = self.next_id;
        self.next_id += 1;

        try self.breakpoints.append(self.allocator, .{
            .id = id,
            .address = address,
            .file = "",
            .line = 0,
            .original_bytes = std.mem.zeroes([bp_size]u8),
            .enabled = true,
            .hit_count = 0,
            .condition = bp.condition,
            .hit_condition = bp.hit_condition,
        });

        return id;
    }

    /// Write a trap instruction to the breakpoint address in the target process.
    pub fn writeBreakpoint(self: *BreakpointManager, id: u32, process: *process_mod.ProcessControl) !void {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id and bp.enabled) {
                // Read original bytes
                const mem = try process.readMemory(bp.address, bp_size, self.allocator);
                defer self.allocator.free(mem);
                @memcpy(&bp.original_bytes, mem[0..bp_size]);

                // Write trap instruction (BRK #0 on ARM64, INT3 on x86)
                try process.writeMemory(bp.address, trap_instruction);
                return;
            }
        }
        return error.BreakpointNotFound;
    }

    /// Restore original bytes at breakpoint address.
    pub fn removeBreakpoint(self: *BreakpointManager, id: u32, process: *process_mod.ProcessControl) !void {
        for (self.breakpoints.items, 0..) |*bp, i| {
            if (bp.id == id) {
                if (bp.enabled) {
                    try process.writeMemory(bp.address, &bp.original_bytes);
                }
                if (bp.file.len > 0) self.allocator.free(bp.file);
                _ = self.breakpoints.swapRemove(i);
                return;
            }
        }
        return error.BreakpointNotFound;
    }

    /// Remove a breakpoint by id without process interaction (for testing).
    pub fn remove(self: *BreakpointManager, id: u32) !void {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id == id) {
                if (bp.file.len > 0) self.allocator.free(bp.file);
                _ = self.breakpoints.swapRemove(i);
                return;
            }
        }
        return error.BreakpointNotFound;
    }

    /// Check if an address matches a breakpoint, and return it.
    pub fn findByAddress(self: *BreakpointManager, address: u64) ?*Breakpoint {
        for (self.breakpoints.items) |*bp| {
            if (bp.address == address and bp.enabled) {
                return bp;
            }
        }
        return null;
    }

    /// Find a breakpoint by ID.
    pub fn findById(self: *BreakpointManager, id: u32) ?*Breakpoint {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id) return bp;
        }
        return null;
    }

    /// List all breakpoints.
    pub fn list(self: *const BreakpointManager) []const Breakpoint {
        return self.breakpoints.items;
    }

    /// Record a hit on a breakpoint.
    pub fn recordHit(self: *BreakpointManager, id: u32) void {
        if (self.findById(id)) |bp| {
            bp.hit_count += 1;
        }
    }

    /// Callback type for evaluating breakpoint condition expressions.
    /// The engine provides an evaluator that resolves the condition string
    /// against the debuggee's current state.
    pub const ConditionEvaluator = struct {
        ctx: *anyopaque,
        evalFn: *const fn (ctx: *anyopaque, condition: []const u8) bool,

        pub fn eval(self: ConditionEvaluator, condition: []const u8) bool {
            return self.evalFn(self.ctx, condition);
        }
    };

    /// Check whether execution should stop at this breakpoint.
    /// Increments hit_count and evaluates the condition and hit_condition if present.
    /// Returns true if we should stop, false to silently continue.
    pub fn shouldStop(_: *BreakpointManager, bp: *Breakpoint, evaluator: ?ConditionEvaluator) bool {
        bp.hit_count += 1;

        // Check expression condition first
        if (bp.condition) |cond| {
            if (evaluator) |eval| {
                if (!eval.eval(cond)) return false;
            }
        }

        // Check hit condition
        if (bp.hit_condition) |hc| {
            return evaluateHitCondition(hc, bp.hit_count);
        }

        // Log points never stop (they log and continue)
        if (bp.log_message != null) return false;

        return true;
    }

    /// Parse and evaluate a hit condition string against the current hit count.
    /// Supported formats: ">= N", "> N", "== N", "= N", "% N", "<= N", "< N"
    pub fn evaluateHitCondition(hc: []const u8, hit_count: u32) bool {
        const trimmed = std.mem.trim(u8, hc, " ");
        if (trimmed.len == 0) return true;

        // Try to parse as plain number first (equivalent to "== N")
        if (std.fmt.parseInt(u32, trimmed, 10)) |n| {
            return hit_count == n;
        } else |_| {}

        // Parse operator and number
        var op_end: usize = 0;
        while (op_end < trimmed.len and !std.ascii.isDigit(trimmed[op_end])) : (op_end += 1) {}
        const op = std.mem.trim(u8, trimmed[0..op_end], " ");
        const num_str = std.mem.trim(u8, trimmed[op_end..], " ");
        const n = std.fmt.parseInt(u32, num_str, 10) catch return true;

        if (std.mem.eql(u8, op, ">=")) return hit_count >= n;
        if (std.mem.eql(u8, op, ">")) return hit_count > n;
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) return hit_count == n;
        if (std.mem.eql(u8, op, "<=")) return hit_count <= n;
        if (std.mem.eql(u8, op, "<")) return hit_count < n;
        if (std.mem.eql(u8, op, "%")) return if (n > 0) (hit_count % n == 0) else true;

        return true; // Unknown operator — stop
    }
};

/// Look up a file name from file entries by 0-based index.
fn getEntryFileName(files: []const parser.FileEntry, index: u32) []const u8 {
    if (index < files.len) return files[index].name;
    return "<unknown>";
}

/// Flexible file path matching that handles common path variations.
/// Matches if: exact match, basename match, or one path is a suffix of the other.
pub fn filePathsMatch(requested: []const u8, entry_path: []const u8) bool {
    return fileMatchQuality(requested, entry_path) > 0;
}

/// Returns match quality: 3=exact, 2=suffix, 1=basename, 0=no match.
/// Higher quality means a more specific match. Use this to prefer exact/suffix
/// matches over basename-only matches when multiple entries match.
pub fn fileMatchQuality(requested: []const u8, entry_path: []const u8) u8 {
    // Exact match
    if (std.mem.eql(u8, requested, entry_path)) return 3;
    // Suffix match: requested ends with entry or vice versa
    if (std.mem.endsWith(u8, requested, entry_path) or std.mem.endsWith(u8, entry_path, requested)) return 2;
    // Basename match: "foo.go" matches "/some/path/foo.go"
    const req_base = std.fs.path.basename(requested);
    const entry_base = std.fs.path.basename(entry_path);
    if (std.mem.eql(u8, req_base, entry_base)) return 1;
    return 0;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "BreakpointManager initial state" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.list().len);
}

test "resolveBreakpoint maps file:line to address via debug_line" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1010, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 15, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const bp = try mgr.resolveAndSet("test.c", 10, &entries, &.{}, null);
    try std.testing.expectEqual(@as(u64, 0x1010), bp.address);
    try std.testing.expectEqual(@as(u32, 10), bp.line);
}

test "resolveBreakpoint finds nearest line when exact not available" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1020, .file_index = 1, .line = 15, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    // Request line 10 but only 5 and 15 exist — should get 15 (nearest >= requested)
    const bp = try mgr.resolveAndSet("test.c", 10, &entries, &.{}, null);
    try std.testing.expectEqual(@as(u32, 15), bp.line);
    try std.testing.expectEqual(@as(u64, 0x1020), bp.address);
}

test "setBreakpoint assigns incrementing IDs" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id1 = try mgr.setAtAddress(0x1000, "a.c", 1);
    const id2 = try mgr.setAtAddress(0x2000, "b.c", 2);

    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
    try std.testing.expectEqual(@as(usize, 2), mgr.list().len);
}

test "remove breakpoint removes from list" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);
    try std.testing.expectEqual(@as(usize, 1), mgr.list().len);

    try mgr.remove(id);
    try std.testing.expectEqual(@as(usize, 0), mgr.list().len);
}

test "remove nonexistent breakpoint returns error" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    try std.testing.expectError(error.BreakpointNotFound, mgr.remove(999));
}

test "multiple breakpoints track independently" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "a.c", 1);
    const id2 = try mgr.setAtAddress(0x2000, "b.c", 2);
    _ = try mgr.setAtAddress(0x3000, "c.c", 3);

    try mgr.remove(id2);
    try std.testing.expectEqual(@as(usize, 2), mgr.list().len);

    // Remaining breakpoints should still be findable
    try std.testing.expect(mgr.findByAddress(0x1000) != null);
    try std.testing.expect(mgr.findByAddress(0x2000) == null); // removed
    try std.testing.expect(mgr.findByAddress(0x3000) != null);
}

test "findByAddress returns matching breakpoint" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "test.c", 5);

    const bp = mgr.findByAddress(0x1000);
    try std.testing.expect(bp != null);
    try std.testing.expectEqual(@as(u32, 5), bp.?.line);
}

test "findByAddress returns null for unknown address" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "test.c", 5);

    try std.testing.expect(mgr.findByAddress(0x9999) == null);
}

test "recordHit increments hit count" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);
    mgr.recordHit(id);
    mgr.recordHit(id);

    const bp = mgr.findById(id);
    try std.testing.expect(bp != null);
    try std.testing.expectEqual(@as(u32, 2), bp.?.hit_count);
}

test "breakpoint at invalid location returns error" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Only end_sequence entries — no statement lines available
    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 5, .column = 0, .is_stmt = true, .end_sequence = true },
    };

    const result = mgr.resolveAndSet("test.c", 5, &entries, &.{}, null);
    try std.testing.expectError(error.NoAddressForLine, result);
}

test "conditional breakpoint stores condition" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const bp = try mgr.resolveAndSet("test.c", 10, &entries, &.{}, "x > 5");
    try std.testing.expect(bp.condition != null);
    try std.testing.expectEqualStrings("x > 5", bp.condition.?);
}

test "conditional breakpoint evaluates expression" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    _ = try mgr.resolveAndSet("test.c", 10, &entries, &.{}, "x > 5");

    const bp = mgr.findByAddress(0x1000).?;

    // Evaluator that returns false (condition not met) — should not stop
    const result1 = mgr.shouldStop(bp, .{
        .ctx = undefined,
        .evalFn = &struct {
            fn f(_: *anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
    });
    try std.testing.expect(!result1);

    // Evaluator that returns true (condition met) — should stop
    const result2 = mgr.shouldStop(bp, .{
        .ctx = undefined,
        .evalFn = &struct {
            fn f(_: *anyopaque, _: []const u8) bool {
                return true;
            }
        }.f,
    });
    try std.testing.expect(result2);

    // Hit count should be 2 after both evaluations
    try std.testing.expectEqual(@as(u32, 2), bp.hit_count);
}

test "unconditional breakpoint always stops" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    _ = try mgr.setAtAddress(0x1000, "test.c", 5);
    const bp = mgr.findByAddress(0x1000).?;

    // No condition — should always stop regardless of evaluator
    try std.testing.expect(mgr.shouldStop(bp, null));
    try std.testing.expectEqual(@as(u32, 1), bp.hit_count);
}

test "breakpoint hit stops process at correct address" {
    if (builtin.os.tag != .macos or !builtin.single_threaded) return error.SkipZigTest;

    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Set a breakpoint at a known address
    const bp_addr: u64 = 0x4000;
    const id = try mgr.setAtAddress(bp_addr, "test.c", 10);

    // Spawn a process and write the breakpoint
    var pc = process_mod.ProcessControl{};
    pc.spawn(std.testing.allocator, "/bin/echo", &.{"test"}) catch return error.SkipZigTest;
    defer pc.kill() catch {};

    try mgr.writeBreakpoint(id, &pc);

    // Simulate breakpoint hit: find by address and record hit
    const bp = mgr.findByAddress(bp_addr);
    try std.testing.expect(bp != null);
    try std.testing.expectEqual(bp_addr, bp.?.address);
    try std.testing.expectEqual(@as(u32, 10), bp.?.line);

    // Record the hit and verify state
    mgr.recordHit(id);
    try std.testing.expectEqual(@as(u32, 1), bp.?.hit_count);

    // Verify shouldStop returns true (no condition)
    try std.testing.expect(mgr.shouldStop(bp.?, null));
    try std.testing.expectEqual(@as(u32, 2), bp.?.hit_count);
}

test "writeBreakpoint requires a live process" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);

    // ProcessControl with no pid should return NoProcess error
    var pc = process_mod.ProcessControl{};
    try std.testing.expectError(error.NoProcess, mgr.writeBreakpoint(id, &pc));
}

test "removeBreakpoint without process removes from list" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const id = try mgr.setAtAddress(0x1000, "test.c", 5);

    // remove() doesn't need a process — just removes from the list
    try mgr.remove(id);
    try std.testing.expectEqual(@as(usize, 0), mgr.list().len);
}

test "evaluateHitCondition with >= operator" {
    try std.testing.expect(!BreakpointManager.evaluateHitCondition(">= 3", 1));
    try std.testing.expect(!BreakpointManager.evaluateHitCondition(">= 3", 2));
    try std.testing.expect(BreakpointManager.evaluateHitCondition(">= 3", 3));
    try std.testing.expect(BreakpointManager.evaluateHitCondition(">= 3", 4));
}

test "evaluateHitCondition with == operator" {
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("== 5", 4));
    try std.testing.expect(BreakpointManager.evaluateHitCondition("== 5", 5));
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("== 5", 6));
}

test "evaluateHitCondition with modulo operator" {
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("% 3", 1));
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("% 3", 2));
    try std.testing.expect(BreakpointManager.evaluateHitCondition("% 3", 3));
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("% 3", 4));
    try std.testing.expect(BreakpointManager.evaluateHitCondition("% 3", 6));
}

test "evaluateHitCondition with plain number" {
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("3", 2));
    try std.testing.expect(BreakpointManager.evaluateHitCondition("3", 3));
    try std.testing.expect(!BreakpointManager.evaluateHitCondition("3", 4));
}

test "hit_condition breakpoint stops on correct hit" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    _ = try mgr.resolveAndSetEx("test.c", 10, &entries, &.{}, null, ">= 3", null);
    const bp = mgr.findByAddress(0x1000).?;

    // Hits 1 and 2 should not stop
    try std.testing.expect(!mgr.shouldStop(bp, null));
    try std.testing.expect(!mgr.shouldStop(bp, null));
    // Hit 3 should stop
    try std.testing.expect(mgr.shouldStop(bp, null));
    // Hit 4 should also stop (>= 3)
    try std.testing.expect(mgr.shouldStop(bp, null));
}

test "log point breakpoint never stops" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    _ = try mgr.resolveAndSetEx("test.c", 10, &entries, &.{}, null, null, "x = {x}");
    const bp = mgr.findByAddress(0x1000).?;

    // Log points should never stop
    try std.testing.expect(!mgr.shouldStop(bp, null));
    try std.testing.expect(!mgr.shouldStop(bp, null));
    try std.testing.expect(!mgr.shouldStop(bp, null));
}

test "column field is stored correctly on breakpoints" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 5, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1008, .file_index = 1, .line = 10, .column = 20, .is_stmt = true, .end_sequence = false },
    };

    // Set a breakpoint with column specified
    const bp = try mgr.resolveAndSetColumn("test.c", 10, 5, &entries, &.{}, null, null, null);
    try std.testing.expectEqual(@as(?u32, 5), bp.column);
    try std.testing.expectEqual(@as(u64, 0x1000), bp.address);
    try std.testing.expectEqual(@as(u32, 10), bp.line);

    // Set a breakpoint without column — column should be null
    const bp2 = try mgr.resolveAndSetEx("test.c", 10, &entries, &.{}, null, null, null);
    try std.testing.expect(bp2.column == null);
}

test "column matching prefers more specific matches" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const entries = [_]parser.LineEntry{
        .{ .address = 0x1000, .file_index = 1, .line = 10, .column = 5, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1008, .file_index = 1, .line = 10, .column = 20, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x1010, .file_index = 1, .line = 10, .column = 35, .is_stmt = true, .end_sequence = false },
    };

    // Request column 20 — should match exactly at 0x1008
    const bp1 = try mgr.resolveAndSetColumn("test.c", 10, 20, &entries, &.{}, null, null, null);
    try std.testing.expectEqual(@as(u64, 0x1008), bp1.address);

    // Request column 22 — should match closest at column 20 (distance 2) vs 35 (distance 13) vs 5 (distance 17)
    const bp2 = try mgr.resolveAndSetColumn("test.c", 10, 22, &entries, &.{}, null, null, null);
    try std.testing.expectEqual(@as(u64, 0x1008), bp2.address);

    // Request column 30 — should match closest at column 35 (distance 5) vs 20 (distance 10) vs 5 (distance 25)
    const bp3 = try mgr.resolveAndSetColumn("test.c", 10, 30, &entries, &.{}, null, null, null);
    try std.testing.expectEqual(@as(u64, 0x1010), bp3.address);

    // Request column 1 — should match closest at column 5 (distance 4)
    const bp4 = try mgr.resolveAndSetColumn("test.c", 10, 1, &entries, &.{}, null, null, null);
    try std.testing.expectEqual(@as(u64, 0x1000), bp4.address);
}

test "instruction breakpoint sets at correct address" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const ibp = types.InstructionBreakpoint{
        .instruction_reference = "0x4000",
    };
    const id = try mgr.setInstructionBreakpoint(ibp);
    const bp = mgr.findById(id).?;
    try std.testing.expectEqual(@as(u64, 0x4000), bp.address);
    try std.testing.expect(bp.enabled);
}

test "instruction breakpoint with offset applied" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Positive offset
    const ibp1 = types.InstructionBreakpoint{
        .instruction_reference = "0x4000",
        .offset = 16,
    };
    const id1 = try mgr.setInstructionBreakpoint(ibp1);
    const bp1 = mgr.findById(id1).?;
    try std.testing.expectEqual(@as(u64, 0x4010), bp1.address);

    // Negative offset
    const ibp2 = types.InstructionBreakpoint{
        .instruction_reference = "0x4000",
        .offset = -8,
    };
    const id2 = try mgr.setInstructionBreakpoint(ibp2);
    const bp2 = mgr.findById(id2).?;
    try std.testing.expectEqual(@as(u64, 0x3FF8), bp2.address);
}

test "instruction breakpoint without 0x prefix" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const ibp = types.InstructionBreakpoint{
        .instruction_reference = "ABCD",
    };
    const id = try mgr.setInstructionBreakpoint(ibp);
    const bp = mgr.findById(id).?;
    try std.testing.expectEqual(@as(u64, 0xABCD), bp.address);
}

test "instruction breakpoint with condition" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const ibp = types.InstructionBreakpoint{
        .instruction_reference = "0x5000",
        .condition = "rax == 0",
        .hit_condition = ">= 3",
    };
    const id = try mgr.setInstructionBreakpoint(ibp);
    const bp = mgr.findById(id).?;
    try std.testing.expectEqual(@as(u64, 0x5000), bp.address);
    try std.testing.expectEqualStrings("rax == 0", bp.condition.?);
    try std.testing.expectEqualStrings(">= 3", bp.hit_condition.?);
}

test "instruction breakpoint with invalid reference returns error" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    const ibp = types.InstructionBreakpoint{
        .instruction_reference = "not_hex",
    };
    try std.testing.expectError(error.InvalidInstructionReference, mgr.setInstructionBreakpoint(ibp));
}

test "breakpoint prefers exact path over basename-only match" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Simulate Rust DWARF: stdlib file with same basename appears first at line 547,
    // user's actual file appears later at line 2.
    const file_entries = [_]parser.FileEntry{
        .{ .name = "/rustc/abc123/library/std/src/debug_test.rs", .dir_index = 0 },
        .{ .name = "/tmp/debug_test.rs", .dir_index = 0 },
    };

    const line_entries = [_]parser.LineEntry{
        // stdlib entry: basename matches but path doesn't — quality 1
        .{ .address = 0xBAD, .file_index = 0, .line = 2, .column = 0, .is_stmt = true, .end_sequence = false },
        // user entry: suffix matches "/tmp/debug_test.rs" — quality 2
        .{ .address = 0x2000, .file_index = 1, .line = 2, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    const bp = try mgr.resolveAndSet("/tmp/debug_test.rs", 2, &line_entries, &file_entries, null);
    // Should resolve to user's file (0x2000), NOT stdlib (0xBAD)
    try std.testing.expectEqual(@as(u64, 0x2000), bp.address);
    try std.testing.expectEqual(@as(u32, 2), bp.line);
}

test "exact line match preferred over earlier fallback in address order" {
    var mgr = BreakpointManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Simulates Rust codegen unit layout where functions are NOT in source order.
    // Memory layout: add() at 0x1000 → main() at 0x2000 → multiply() at 0x3000
    // Source lines: add=line 2, main=line 33, multiply=line 7
    // When searching for line 7 (in multiply), the resolver iterates by address
    // and hits main's line 33 (a fallback >= 7) before reaching multiply's exact line 7.
    const file_entries = [_]parser.FileEntry{
        .{ .name = "/tmp/test.rs", .dir_index = 0 },
    };

    const line_entries = [_]parser.LineEntry{
        // add() function: line 2
        .{ .address = 0x1000, .file_index = 0, .line = 2, .column = 0, .is_stmt = true, .end_sequence = false },
        // main() function: line 33 — appears BEFORE multiply in address order
        .{ .address = 0x2000, .file_index = 0, .line = 33, .column = 0, .is_stmt = true, .end_sequence = false },
        .{ .address = 0x2010, .file_index = 0, .line = 34, .column = 0, .is_stmt = true, .end_sequence = false },
        // multiply() function: line 7 — the exact match, but later in address order
        .{ .address = 0x3000, .file_index = 0, .line = 7, .column = 0, .is_stmt = true, .end_sequence = false },
    };

    // Searching for line 7 should find the exact match at 0x3000,
    // NOT the fallback at 0x2000 (line 33 >= 7).
    const bp = try mgr.resolveAndSet("/tmp/test.rs", 7, &line_entries, &file_entries, null);
    try std.testing.expectEqual(@as(u64, 0x3000), bp.address);
    try std.testing.expectEqual(@as(u32, 7), bp.line);
}
