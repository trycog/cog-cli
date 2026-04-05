const std = @import("std");
const posix = std.posix;

// ── Types ───────────────────────────────────────────────────────────────

pub const MenuItem = struct {
    label: []const u8,
    is_input_option: bool = false,
};

pub const SelectResult = union(enum) {
    selected: usize,
    input: []const u8,
    back: void,
    cancelled: void,
};

pub const MultiSelectResult = union(enum) {
    selected: []const usize, // caller must free
    back: void,
    cancelled: void,
};

pub const MultiSelectOptions = struct {
    prompt: []const u8,
    items: []const MenuItem,
    initial_selected: ?[]const bool = null,
};

pub const InputValidator = *const fn ([]const u8) ?[]const u8;

pub const SelectOptions = struct {
    prompt: []const u8,
    items: []const MenuItem,
    initial: usize = 0,
    input_validator: ?InputValidator = null,
};

// ── Input Events ────────────────────────────────────────────────────────

const InputEvent = union(enum) {
    arrow_up: void,
    arrow_down: void,
    enter: void,
    escape: void,
    ctrl_c: void,
    backspace: void,
    char: u8,
};

// ── Raw Terminal ────────────────────────────────────────────────────────

const RawTerminal = struct {
    original: posix.termios,
    fd: posix.fd_t,

    fn enter(fd: posix.fd_t) !RawTerminal {
        const original = try posix.tcgetattr(fd);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        try posix.tcsetattr(fd, .NOW, raw);
        return .{ .original = original, .fd = fd };
    }

    fn leave(self: *const RawTerminal) void {
        posix.tcsetattr(self.fd, .NOW, self.original) catch {};
    }

    fn readInputEvent(self: *const RawTerminal) !InputEvent {
        var buf: [1]u8 = undefined;
        const n = try posix.read(self.fd, &buf);
        if (n == 0) return .escape;

        return switch (buf[0]) {
            '\r', '\n' => .enter,
            27 => self.readEscapeSequence(),
            3 => .ctrl_c,
            127, 8 => .backspace,
            32...126 => .{ .char = buf[0] },
            else => self.readInputEvent(),
        };
    }

    fn readEscapeSequence(self: *const RawTerminal) !InputEvent {
        var timeout_term = self.original;
        timeout_term.lflag.ICANON = false;
        timeout_term.lflag.ECHO = false;
        timeout_term.lflag.ISIG = false;
        timeout_term.cc[@intFromEnum(std.c.V.MIN)] = 0;
        timeout_term.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try posix.tcsetattr(self.fd, .NOW, timeout_term);
        defer {
            var restore = self.original;
            restore.lflag.ICANON = false;
            restore.lflag.ECHO = false;
            restore.lflag.ISIG = false;
            restore.cc[@intFromEnum(std.c.V.MIN)] = 1;
            restore.cc[@intFromEnum(std.c.V.TIME)] = 0;
            posix.tcsetattr(self.fd, .NOW, restore) catch {};
        }

        var buf: [1]u8 = undefined;
        const n1 = posix.read(self.fd, &buf) catch return .escape;
        if (n1 == 0) return .escape;

        if (buf[0] != '[') return .escape;

        const n2 = posix.read(self.fd, &buf) catch return .escape;
        if (n2 == 0) return .escape;

        return switch (buf[0]) {
            'A' => .arrow_up,
            'B' => .arrow_down,
            else => .escape,
        };
    }
};

// ── Stderr Writer Helper ────────────────────────────────────────────────

fn stderrWrite(data: []const u8) void {
    if (@import("builtin").is_test) return;
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(data) catch {};
    w.interface.flush() catch {};
}

fn stderrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stderrWrite(msg);
}

// ── Visual Constants ────────────────────────────────────────────────────

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// Unicode glyphs
const bullet_filled = "\xE2\x97\x8F"; // ●
const bullet_open = "\xE2\x97\x8B"; // ○
const check = "\xE2\x9C\x93"; // ✓
const cross = "\xE2\x9C\x97"; // ✗
const block_cursor = "\xE2\x96\x88"; // █

// Composed prefixes — visual width: 4 columns ("  ● ")
const indicator_on = "  " ++ cyan ++ bullet_filled ++ reset ++ " ";
const indicator_off = "  " ++ dim ++ bullet_open ++ reset ++ " ";

// ── Box-Drawing Characters ─────────────────────────────────────────────

const hh = "\xE2\x94\x80"; // ─
const vv = "\xE2\x94\x82"; // │
const ct = "\xE2\x94\x8C"; // ┌
const cb = "\xE2\x94\x94"; // └
const tr = "\xE2\x94\x90"; // ┐
const br = "\xE2\x94\x98"; // ┘
const h3 = hh ++ hh ++ hh;
const h4 = h3 ++ hh;

// ── Public Helpers ──────────────────────────────────────────────────────

/// Check if stderr is a TTY (for progress display gating).
pub fn isStderrTty() bool {
    if (@import("builtin").is_test) return false;
    return posix.isatty(std.fs.File.stderr().handle);
}

/// Print the Cog ASCII art header
pub fn header() void {
    stderrWrite("\n" ++ cyan);
    stderrWrite("  " ++ ct ++ h4 ++ "  " ++ ct ++ h3 ++ tr ++ "  " ++ ct ++ h4 ++ "\n");
    stderrWrite("  " ++ vv ++ "      " ++ vv ++ "   " ++ vv ++ "  " ++ vv ++ "\n");
    stderrWrite("  " ++ vv ++ "      " ++ vv ++ "   " ++ vv ++ "  " ++ vv ++ " " ++ hh ++ hh ++ tr ++ "\n");
    stderrWrite("  " ++ cb ++ h4 ++ "  " ++ cb ++ h3 ++ br ++ "  " ++ cb ++ h3 ++ br ++ "\n");
    stderrWrite(reset);
    stderrWrite(dim ++ "  Tools for AI coding\n" ++ reset);
    stderrWrite("\n");
}

/// Print a cyan ✓ to stderr (no newline)
pub fn checkmark() void {
    stderrWrite(cyan ++ check ++ reset);
}

/// Print a dim horizontal rule to stderr
pub fn separator() void {
    stderrWrite(dim ++ "  \xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80" ++ reset ++ "\n");
}

// ── Progress Display ─────────────────────────────────────────────────────

/// Format a number with comma separators (e.g., 1234 → "1,234").
/// Returns the formatted slice within the provided buffer.
fn formatNumber(buf: []u8, n: usize) []const u8 {
    if (n == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    // First, write digits in reverse
    var tmp: [20]u8 = undefined;
    var tmp_len: usize = 0;
    var val = n;
    while (val > 0) : (tmp_len += 1) {
        tmp[tmp_len] = @intCast('0' + val % 10);
        val /= 10;
    }

    // Now write to buf with commas (grouped from the right)
    var pos: usize = 0;
    var i: usize = 0;
    while (i < tmp_len) : (i += 1) {
        if (i > 0 and (tmp_len - i) % 3 == 0) {
            buf[pos] = ',';
            pos += 1;
        }
        buf[pos] = tmp[tmp_len - 1 - i];
        pos += 1;
    }
    return buf[0..pos];
}

/// Truncate a file path to fit within max_len chars.
/// If too long, returns "..." + last (max_len - 3) chars.
fn sanitizePathBytes(buf: []u8, path: []const u8) []const u8 {
    const len = @min(buf.len, path.len);
    for (path[0..len], 0..) |byte, i| {
        buf[i] = switch (byte) {
            32...126 => byte,
            else => '?',
        };
    }
    return buf[0..len];
}

fn truncatePath(buf: []u8, path: []const u8, max_len: usize) []const u8 {
    if (path.len <= max_len) return sanitizePathBytes(buf, path);
    const suffix_len = max_len - 3;
    buf[0] = '.';
    buf[1] = '.';
    buf[2] = '.';
    _ = sanitizePathBytes(buf[3..][0..suffix_len], path[path.len - suffix_len ..]);
    return buf[0..max_len];
}

test "truncatePath sanitizes non-printable bytes" {
    var buf: [32]u8 = undefined;
    const rendered = truncatePath(&buf, "src/\xffdebug/\x00file.zig", 32);
    try std.testing.expectEqualStrings("src/?debug/?file.zig", rendered);
}

// Box-drawing characters for progress bar
const bar_filled = "\xE2\x94\x81"; // ━ (heavy horizontal)
const bar_empty = "\xE2\x94\x80"; // ─ (light horizontal)
const bar_width = 30;

/// Render a progress bar into a buffer. Returns the written slice.
/// Format: "━━━━━━━━━━──────────────────── 42%"
fn renderBar(buf: []u8, current: usize, total: usize) []const u8 {
    const pct: usize = if (total == 0) 0 else @min(current * 100 / total, 100);
    const filled: usize = if (total == 0) 0 else @min(current * bar_width / total, bar_width);

    var pos: usize = 0;

    // Cyan for filled portion
    const cyan_bytes = cyan;
    @memcpy(buf[pos..][0..cyan_bytes.len], cyan_bytes);
    pos += cyan_bytes.len;

    for (0..filled) |_| {
        @memcpy(buf[pos..][0..bar_filled.len], bar_filled);
        pos += bar_filled.len;
    }

    // Dim for empty portion
    const dim_bytes = dim;
    @memcpy(buf[pos..][0..dim_bytes.len], dim_bytes);
    pos += dim_bytes.len;

    for (0..bar_width - filled) |_| {
        @memcpy(buf[pos..][0..bar_empty.len], bar_empty);
        pos += bar_empty.len;
    }

    // Reset + percentage
    const reset_bytes = reset;
    @memcpy(buf[pos..][0..reset_bytes.len], reset_bytes);
    pos += reset_bytes.len;

    // " NNN%"
    const pct_str = std.fmt.bufPrint(buf[pos..], " {d}%", .{pct}) catch return buf[0..pos];
    pos += pct_str.len;

    return buf[0..pos];
}

/// Print the initial progress block (6 lines):
///   Indexing\n \n     bar 0%\n     Files  0 / total\n     Symbols  0\n     \n
pub fn progressStart(total_files: usize) void {
    stderrWrite("  " ++ cyan ++ bold ++ "Indexing" ++ reset ++ "\n");
    stderrWrite("\n");
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, 0, total_files));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Files" ++ reset ++ "    0 / ");
    stderrWrite(formatNumber(&num_buf, total_files));
    stderrWrite("\n");
    stderrWrite("    " ++ bold ++ "Symbols" ++ reset ++ "  0\n");
    stderrWrite("\n");
}

/// Update the bottom 4 progress lines (bar, Files, Symbols, current file).
pub fn progressUpdate(files: usize, total_files: usize, symbols: usize, current_file: []const u8) void {
    clearLines(4);
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, files, total_files));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Files" ++ reset ++ "    ");
    stderrWrite(formatNumber(&num_buf, files));
    stderrWrite(" / ");
    stderrWrite(formatNumber(&num_buf, total_files));
    stderrWrite("\n");
    stderrWrite("    " ++ bold ++ "Symbols" ++ reset ++ "  ");
    stderrWrite(formatNumber(&num_buf, symbols));
    stderrWrite("\n");
    var path_buf: [64]u8 = undefined;
    stderrWrite("    " ++ dim);
    stderrWrite(truncatePath(&path_buf, current_file, 60));
    stderrWrite(reset ++ "\n");
}

/// Replace all 6 progress lines with final state (Indexing ✓ + stats + path).
pub fn progressFinish(files: usize, symbols: usize, skipped: usize, index_path: []const u8) void {
    clearLines(6);
    stderrWrite("  " ++ cyan ++ bold ++ "Indexing " ++ check ++ reset ++ "\n");
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Files" ++ reset ++ "    ");
    stderrWrite(formatNumber(&num_buf, files));
    if (skipped > 0) {
        stderrWrite(dim ++ "  (");
        stderrWrite(formatNumber(&num_buf, skipped));
        stderrWrite(" skipped)" ++ reset);
    }
    stderrWrite("\n");
    stderrWrite("    " ++ bold ++ "Symbols" ++ reset ++ "  ");
    stderrWrite(formatNumber(&num_buf, symbols));
    stderrWrite("\n");
    var path_buf: [64]u8 = undefined;
    stderrWrite("    " ++ dim);
    stderrWrite(truncatePath(&path_buf, index_path, 60));
    stderrWrite(reset ++ "\n");
}

// ── Upload Progress ─────────────────────────────────────────────────────

/// Print the initial upload progress block (4 lines):
///   Migrating\n \n     bar 0%\n     Engrams  0 / total  |  Synapses  0 / total\n
pub fn uploadProgressStart(total_engrams: usize, total_synapses: usize) void {
    stderrWrite("  " ++ cyan ++ bold ++ "Migrating" ++ reset ++ "\n");
    stderrWrite("\n");
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, 0, total_engrams + total_synapses));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Engrams" ++ reset ++ "   0 / ");
    stderrWrite(formatNumber(&num_buf, total_engrams));
    stderrWrite("  " ++ dim ++ "|" ++ reset ++ "  " ++ bold ++ "Synapses" ++ reset ++ "  0 / ");
    stderrWrite(formatNumber(&num_buf, total_synapses));
    stderrWrite("\n");
}

/// Update the upload progress lines (bottom 3 of 4).
pub fn uploadProgressUpdate(engrams: usize, total_engrams: usize, synapses: usize, total_synapses: usize) void {
    clearLines(2);
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, engrams + synapses, total_engrams + total_synapses));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Engrams" ++ reset ++ "   ");
    stderrWrite(formatNumber(&num_buf, engrams));
    stderrWrite(" / ");
    stderrWrite(formatNumber(&num_buf, total_engrams));
    stderrWrite("  " ++ dim ++ "|" ++ reset ++ "  " ++ bold ++ "Synapses" ++ reset ++ "  ");
    stderrWrite(formatNumber(&num_buf, synapses));
    stderrWrite(" / ");
    stderrWrite(formatNumber(&num_buf, total_synapses));
    stderrWrite("\n");
}

/// Replace all 4 upload progress lines with final state.
pub fn uploadProgressFinish(engrams: usize, total_engrams: usize, synapses: usize, total_synapses: usize) void {
    clearLines(4);
    stderrWrite("  " ++ cyan ++ bold ++ "Migrated " ++ check ++ reset ++ "\n");
    stderrWrite("\n");
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, total_engrams + total_synapses, total_engrams + total_synapses));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Engrams" ++ reset ++ "   ");
    stderrWrite(formatNumber(&num_buf, engrams));
    stderrWrite(" / ");
    stderrWrite(formatNumber(&num_buf, total_engrams));
    stderrWrite("  " ++ dim ++ "|" ++ reset ++ "  " ++ bold ++ "Synapses" ++ reset ++ "  ");
    stderrWrite(formatNumber(&num_buf, synapses));
    stderrWrite(" / ");
    stderrWrite(formatNumber(&num_buf, total_synapses));
    stderrWrite("\n");
}

// ── Bootstrap Progress ──────────────────────────────────────────────────

/// Format cost from microdollars into a stack buffer. Returns formatted slice.
fn formatCostBuf(buf: []u8, microdollars: usize) []const u8 {
    // Round to nearest cent (10_000 microdollars = 1 cent)
    const rounded = (microdollars + 5_000) / 10_000;
    const dollars = rounded / 100;
    const cents = rounded % 100;
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ dollars, cents }) catch "?.??";
}

/// Print the initial bootstrap progress block (7 lines):
///   <title>\n \n bar 0%\n Files 0/total\n Tokens 0/0\n Cost $0\n \n
pub fn bootstrapStart(title: []const u8, total_files: usize, subtitle: ?[]const u8) void {
    stderrWrite("  " ++ cyan ++ bold);
    stderrWrite(title);
    stderrWrite(reset ++ "\n");
    if (subtitle) |sub| {
        stderrWrite("  Watch the brain build: " ++ cyan);
        stderrWrite(sub);
        stderrWrite(reset ++ "\n");
    }
    stderrWrite("\n");
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, 0, total_files));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Files" ++ reset ++ "    0 / ");
    stderrWrite(formatNumber(&num_buf, total_files));
    stderrWrite("\n");
    stderrWrite("    " ++ bold ++ "Tokens" ++ reset ++ "   0 in / 0 out\n");
    stderrWrite("    " ++ bold ++ "Cost" ++ reset ++ "     $0.00\n");
}

/// Update the bootstrap progress stats (bar, files, tokens, cost).
/// `extra_lines` is the number of file-activity lines drawn below the stats
/// by the ticker thread — they are cleared before redrawing.
pub fn bootstrapUpdate(processed: usize, total: usize, errors: usize, in_tokens: usize, out_tokens: usize, cost_microdollars: usize, extra_lines: usize) void {
    clearLines(4 + extra_lines);
    var bar_buf: [512]u8 = undefined;
    stderrWrite("    ");
    stderrWrite(renderBar(&bar_buf, processed, total));
    stderrWrite("\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Files" ++ reset ++ "    ");
    stderrWrite(formatNumber(&num_buf, processed));
    stderrWrite(" / ");
    stderrWrite(formatNumber(&num_buf, total));
    if (errors > 0) {
        stderrWrite("  " ++ dim ++ "(");
        stderrWrite(formatNumber(&num_buf, errors));
        stderrWrite(" errors)" ++ reset);
    }
    stderrWrite("\n");
    stderrWrite("    " ++ bold ++ "Tokens" ++ reset ++ "   ");
    stderrWrite(formatNumber(&num_buf, in_tokens));
    stderrWrite(" in / ");
    stderrWrite(formatNumber(&num_buf, out_tokens));
    stderrWrite(" out\n");
    stderrWrite("    " ++ bold ++ "Cost" ++ reset ++ "     $");
    var cost_buf: [32]u8 = undefined;
    stderrWrite(formatCostBuf(&cost_buf, cost_microdollars));
    stderrWrite("\n");
}

/// Replace all bootstrap progress lines with final state (title ✓ + stats).
/// `extra_lines` is the number of file-activity lines drawn by the ticker.
pub fn bootstrapFinish(title: []const u8, processed: usize, errors: usize, in_tokens: usize, out_tokens: usize, cost_microdollars: usize, extra_lines: usize) void {
    clearLines(6 + extra_lines);
    stderrWrite("  " ++ cyan ++ bold);
    stderrWrite(title);
    stderrWrite(" " ++ check ++ reset ++ "\n\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Files" ++ reset ++ "    ");
    stderrWrite(formatNumber(&num_buf, processed));
    if (errors > 0) {
        stderrWrite("  " ++ dim ++ "(");
        stderrWrite(formatNumber(&num_buf, errors));
        stderrWrite(" errors)" ++ reset);
    }
    stderrWrite("\n");
    stderrWrite("    " ++ bold ++ "Tokens" ++ reset ++ "   ");
    stderrWrite(formatNumber(&num_buf, in_tokens));
    stderrWrite(" in / ");
    stderrWrite(formatNumber(&num_buf, out_tokens));
    stderrWrite(" out\n");
    stderrWrite("    " ++ bold ++ "Cost" ++ reset ++ "     $");
    var cost_buf: [32]u8 = undefined;
    stderrWrite(formatCostBuf(&cost_buf, cost_microdollars));
    stderrWrite("\n\n");
}

/// Print a bootstrap phase start block (4 lines).
pub fn bootstrapPhaseStart(title: []const u8, label: []const u8, count: usize) void {
    stderrWrite("  " ++ cyan ++ bold);
    stderrWrite(title);
    stderrWrite(reset ++ "\n\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold);
    stderrWrite(label);
    stderrWrite(reset ++ "  ");
    stderrWrite(formatNumber(&num_buf, count));
    stderrWrite("\n");
    stderrWrite("    " ++ dim ++ "Running agent..." ++ reset ++ "\n");
}

/// Finish a bootstrap phase, replacing lines with result.
/// `extra_lines` is the number of file-activity lines drawn by the ticker.
pub fn bootstrapPhaseFinish(title: []const u8, label: []const u8, count: usize, in_tokens: usize, out_tokens: usize, cost_microdollars: usize, success: bool, extra_lines: usize) void {
    clearLines(4 + extra_lines);
    stderrWrite("  " ++ cyan ++ bold);
    stderrWrite(title);
    if (success) {
        stderrWrite(" " ++ check);
    } else {
        stderrWrite(" " ++ cross);
    }
    stderrWrite(reset ++ "\n\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold);
    stderrWrite(label);
    stderrWrite(reset ++ "  ");
    stderrWrite(formatNumber(&num_buf, count));
    stderrWrite("\n");
    if (success) {
        stderrWrite("    " ++ bold ++ "Tokens" ++ reset ++ "   ");
        stderrWrite(formatNumber(&num_buf, in_tokens));
        stderrWrite(" in / ");
        stderrWrite(formatNumber(&num_buf, out_tokens));
        stderrWrite(" out\n");
        stderrWrite("    " ++ bold ++ "Cost" ++ reset ++ "     $");
        var cost_buf: [32]u8 = undefined;
        stderrWrite(formatCostBuf(&cost_buf, cost_microdollars));
        stderrWrite("\n");
    }
    stderrWrite("\n");
}

/// Print a bootstrap total summary (non-live, just appended output).
pub fn bootstrapTotal(in_tokens: usize, out_tokens: usize, cost_microdollars: usize) void {
    stderrWrite("  " ++ bold ++ "Total" ++ reset ++ "\n\n");
    var num_buf: [32]u8 = undefined;
    stderrWrite("    " ++ bold ++ "Tokens" ++ reset ++ "   ");
    stderrWrite(formatNumber(&num_buf, in_tokens));
    stderrWrite(" in / ");
    stderrWrite(formatNumber(&num_buf, out_tokens));
    stderrWrite(" out\n");
    stderrWrite("    " ++ bold ++ "Cost" ++ reset ++ "     $");
    var cost_buf: [32]u8 = undefined;
    stderrWrite(formatCostBuf(&cost_buf, cost_microdollars));
    stderrWrite("\n\n");
}

/// Write a single spinner + file line (no clearing — caller must clear first).
/// Used by the background ticker thread to show activity during long agent calls.
pub fn bootstrapTickLine(spinner: []const u8, label: []const u8, elapsed_s: u64) void {
    stderrWrite("    " ++ dim);
    stderrWrite(spinner);
    stderrWrite(" ");
    var path_buf: [64]u8 = undefined;
    stderrWrite(truncatePath(&path_buf, label, 50));
    var time_buf: [32]u8 = undefined;
    if (elapsed_s >= 60) {
        stderrWrite(std.fmt.bufPrint(&time_buf, " ({d}m {d}s)", .{ elapsed_s / 60, elapsed_s % 60 }) catch "");
    } else {
        stderrWrite(std.fmt.bufPrint(&time_buf, " ({d}s)", .{elapsed_s}) catch "");
    }
    stderrWrite(reset ++ "\n");
}

// ── Select (TTY) ────────────────────────────────────────────────────────

pub fn select(allocator: std.mem.Allocator, options: SelectOptions) !SelectResult {
    if (!posix.isatty(std.fs.File.stdin().handle)) {
        return selectFallback(allocator, options);
    }

    const fd = std.fs.File.stdin().handle;
    var term = try RawTerminal.enter(fd);
    defer term.leave();

    // Hide terminal cursor during menu interaction
    stderrWrite("\x1B[?25l");
    defer stderrWrite("\x1B[?25h");

    var cursor: usize = options.initial;
    var input_buf: [256]u8 = undefined;
    var input_len: usize = 0;
    var validation_error: ?[]const u8 = null;
    const item_count = options.items.len;
    const total_lines = item_count + 1; // prompt line + menu items

    // Initial render
    const on_input = options.items[cursor].is_input_option;
    renderPrompt(options.prompt);
    renderMenu(options, cursor, on_input, input_buf[0..input_len], validation_error);

    while (true) {
        const event = try term.readInputEvent();
        const is_input = options.items[cursor].is_input_option;

        if (is_input) {
            // On an input option — typing goes directly into the buffer
            switch (event) {
                .char => |c| {
                    if (input_len < input_buf.len) {
                        input_buf[input_len] = c;
                        input_len += 1;
                        const old_err = validation_error;
                        validation_error = if (options.input_validator) |v| v(input_buf[0..input_len]) else null;
                        const old_total = total_lines + (if (old_err != null) @as(usize, 1) else 0);
                        redraw(options, old_total, cursor, true, input_buf[0..input_len], validation_error);
                    }
                },
                .backspace => {
                    if (input_len > 0) {
                        input_len -= 1;
                        const old_err = validation_error;
                        validation_error = if (input_len > 0)
                            (if (options.input_validator) |v| v(input_buf[0..input_len]) else null)
                        else
                            null;
                        const old_total = total_lines + (if (old_err != null) @as(usize, 1) else 0);
                        redraw(options, old_total, cursor, true, input_buf[0..input_len], validation_error);
                    }
                },
                .enter => {
                    if (input_len > 0) {
                        if (options.input_validator) |v| {
                            if (v(input_buf[0..input_len])) |_| {
                                continue;
                            }
                        }
                        const result = try allocator.dupe(u8, input_buf[0..input_len]);
                        const err_lines = if (validation_error != null) @as(usize, 1) else 0;
                        clearLines(total_lines + err_lines);
                        renderFinalSelection(options.items, cursor, result);
                        return .{ .input = result };
                    }
                },
                .escape => {
                    if (input_len > 0) {
                        // Clear input, stay on this item
                        const old_err = validation_error;
                        input_len = 0;
                        validation_error = null;
                        const old_total = total_lines + (if (old_err != null) @as(usize, 1) else 0);
                        redraw(options, old_total, cursor, true, input_buf[0..input_len], validation_error);
                    } else {
                        // No input — go back
                        clearLines(total_lines);
                        return .back;
                    }
                },
                .arrow_up, .arrow_down => {
                    const old_err = validation_error;
                    input_len = 0;
                    validation_error = null;
                    if (event == .arrow_up) {
                        if (cursor > 0) cursor -= 1 else cursor = item_count - 1;
                    } else {
                        if (cursor < item_count - 1) cursor += 1 else cursor = 0;
                    }
                    const old_total = total_lines + (if (old_err != null) @as(usize, 1) else 0);
                    const new_on_input = options.items[cursor].is_input_option;
                    redraw(options, old_total, cursor, new_on_input, input_buf[0..input_len], validation_error);
                },
                .ctrl_c => {
                    const err_lines = if (validation_error != null) @as(usize, 1) else 0;
                    clearLines(total_lines + err_lines);
                    return .cancelled;
                },
            }
        } else {
            // On a normal item
            switch (event) {
                .arrow_up => {
                    if (cursor > 0) cursor -= 1 else cursor = item_count - 1;
                    const new_on_input = options.items[cursor].is_input_option;
                    redraw(options, total_lines, cursor, new_on_input, input_buf[0..input_len], validation_error);
                },
                .arrow_down => {
                    if (cursor < item_count - 1) cursor += 1 else cursor = 0;
                    const new_on_input = options.items[cursor].is_input_option;
                    redraw(options, total_lines, cursor, new_on_input, input_buf[0..input_len], validation_error);
                },
                .enter => {
                    clearLines(total_lines);
                    renderFinalSelection(options.items, cursor, null);
                    return .{ .selected = cursor };
                },
                .escape => {
                    clearLines(total_lines);
                    return .back;
                },
                .ctrl_c => {
                    clearLines(total_lines);
                    return .cancelled;
                },
                else => {},
            }
        }
    }
}

fn renderPrompt(prompt: []const u8) void {
    stderrWrite("  " ++ bold);
    stderrWrite(prompt);
    stderrWrite(reset ++ "\n");
}

fn renderMenu(options: SelectOptions, cursor: usize, input_active: bool, input_text: []const u8, validation_error: ?[]const u8) void {
    for (options.items, 0..) |item, i| {
        renderLine(item, i, cursor, input_active, input_text);
    }
    if (validation_error) |err| {
        stderrWrite("    ");
        stderrWrite(err);
        stderrWrite("\n");
    }
}

fn renderLine(item: MenuItem, idx: usize, cursor: usize, input_active: bool, input_text: []const u8) void {
    const is_selected = idx == cursor;
    if (is_selected) {
        stderrWrite(indicator_on);
    } else {
        stderrWrite(indicator_off);
    }

    if (item.is_input_option) {
        if (is_selected and input_active and input_text.len > 0) {
            // Typing — show input text bold with cyan cursor
            stderrWrite(bold);
            stderrWrite(input_text);
            stderrWrite(reset ++ cyan ++ block_cursor ++ reset);
        } else {
            // Show label dimmed
            stderrWrite(dim);
            stderrWrite(item.label);
            stderrWrite(reset);
        }
    } else if (is_selected) {
        stderrWrite(bold);
        stderrWrite(item.label);
        stderrWrite(reset);
    } else {
        stderrWrite(item.label);
    }
    stderrWrite("\n");
}

fn redraw(options: SelectOptions, old_line_count: usize, cursor: usize, input_active: bool, input_text: []const u8, validation_error: ?[]const u8) void {
    clearLines(old_line_count);
    renderPrompt(options.prompt);
    renderMenu(options, cursor, input_active, input_text, validation_error);
}

pub fn clearLines(line_count: usize) void {
    if (line_count == 0) return;
    stderrFmt("\x1B[{d}A", .{line_count});
    for (0..line_count) |_| {
        stderrWrite("\x1B[2K\n");
    }
    stderrFmt("\x1B[{d}A", .{line_count});
}

fn renderFinalSelection(items: []const MenuItem, cursor: usize, input_text: ?[]const u8) void {
    stderrWrite(indicator_on);
    stderrWrite(bold);
    if (input_text) |text| {
        stderrWrite(text);
    } else {
        stderrWrite(items[cursor].label);
    }
    stderrWrite(reset ++ "\n");
}

// ── Select (Non-TTY Fallback) ───────────────────────────────────────────

fn selectFallback(allocator: std.mem.Allocator, options: SelectOptions) !SelectResult {
    stderrWrite("  ");
    stderrWrite(options.prompt);
    stderrWrite("\n");
    for (options.items, 0..) |item, i| {
        stderrFmt("    {d}. ", .{i + 1});
        stderrWrite(item.label);
        stderrWrite("\n");
    }
    stderrWrite("  > ");

    const line = readLine(allocator) catch return .cancelled;
    defer allocator.free(line);

    if (line.len == 0) return .cancelled;

    const num = std.fmt.parseInt(usize, line, 10) catch {
        return .cancelled;
    };
    if (num < 1 or num > options.items.len) return .cancelled;

    const idx = num - 1;
    if (options.items[idx].is_input_option) {
        stderrWrite("  ");
        stderrWrite(options.items[idx].label);
        stderrWrite(": ");
        const input = readLine(allocator) catch return .cancelled;
        if (input.len == 0) {
            allocator.free(input);
            return .cancelled;
        }
        return .{ .input = input };
    }

    return .{ .selected = idx };
}

fn readLine(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [1024]u8 = undefined;
    const n = try posix.read(std.fs.File.stdin().handle, &buf);
    if (n == 0) return error.EndOfStream;
    var line = buf[0..n];
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return allocator.dupe(u8, line);
}

// ── Multi-Select (TTY) ──────────────────────────────────────────────────

pub fn multiSelect(allocator: std.mem.Allocator, options: MultiSelectOptions) !MultiSelectResult {
    if (!posix.isatty(std.fs.File.stdin().handle)) {
        return multiSelectFallback(allocator, options);
    }

    const fd = std.fs.File.stdin().handle;
    var term = try RawTerminal.enter(fd);
    defer term.leave();

    // Hide terminal cursor during menu interaction
    stderrWrite("\x1B[?25l");
    defer stderrWrite("\x1B[?25h");

    var cursor: usize = 0;
    const item_count = options.items.len;
    const total_lines = item_count + 2; // prompt + items + hint

    // Selection state
    var selected: [16]bool = .{false} ** 16;
    if (options.initial_selected) |init| {
        const copy_len = @min(init.len, 16);
        @memcpy(selected[0..copy_len], init[0..copy_len]);
    }

    // Initial render
    renderPrompt(options.prompt);
    renderMultiSelectMenu(options.items, cursor, &selected);
    stderrWrite(dim ++ "    (space to toggle, enter to confirm)" ++ reset ++ "\n");

    while (true) {
        const event = try term.readInputEvent();
        switch (event) {
            .arrow_up => {
                if (cursor > 0) cursor -= 1 else cursor = item_count - 1;
                clearLines(total_lines);
                renderPrompt(options.prompt);
                renderMultiSelectMenu(options.items, cursor, &selected);
                stderrWrite(dim ++ "    (space to toggle, enter to confirm)" ++ reset ++ "\n");
            },
            .arrow_down => {
                if (cursor < item_count - 1) cursor += 1 else cursor = 0;
                clearLines(total_lines);
                renderPrompt(options.prompt);
                renderMultiSelectMenu(options.items, cursor, &selected);
                stderrWrite(dim ++ "    (space to toggle, enter to confirm)" ++ reset ++ "\n");
            },
            .char => |c| {
                if (c == ' ') {
                    selected[cursor] = !selected[cursor];
                    clearLines(total_lines);
                    renderPrompt(options.prompt);
                    renderMultiSelectMenu(options.items, cursor, &selected);
                    stderrWrite(dim ++ "    (space to toggle, enter to confirm)" ++ reset ++ "\n");
                }
            },
            .enter => {
                // Count selected
                var count: usize = 0;
                for (options.items, 0..) |_, i| {
                    if (selected[i]) count += 1;
                }
                if (count == 0) continue; // require at least one selection

                // Build result array
                var result = try allocator.alloc(usize, count);
                var idx: usize = 0;
                for (options.items, 0..) |_, i| {
                    if (selected[i]) {
                        result[idx] = i;
                        idx += 1;
                    }
                }

                // Final render: show only selected items
                clearLines(total_lines);
                renderPrompt(options.prompt);
                for (options.items, 0..) |item, i| {
                    if (selected[i]) {
                        stderrWrite("    " ++ cyan ++ indicator_on ++ reset ++ " " ++ bold);
                        stderrWrite(item.label);
                        stderrWrite(reset ++ "\n");
                    }
                }

                return .{ .selected = result };
            },
            .escape => {
                clearLines(total_lines);
                return .back;
            },
            .ctrl_c => {
                clearLines(total_lines);
                return .cancelled;
            },
            else => {},
        }
    }
}

fn renderMultiSelectMenu(items: []const MenuItem, cursor: usize, selected: *const [16]bool) void {
    for (items, 0..) |item, i| {
        if (i == cursor) {
            if (selected[i]) {
                stderrWrite("    " ++ cyan ++ indicator_on ++ reset ++ " " ++ bold);
            } else {
                stderrWrite("    " ++ dim ++ indicator_off ++ reset ++ " " ++ bold);
            }
            stderrWrite(item.label);
            stderrWrite(reset ++ "\n");
        } else {
            if (selected[i]) {
                stderrWrite("    " ++ cyan ++ indicator_on ++ reset ++ " ");
            } else {
                stderrWrite("    " ++ dim ++ indicator_off ++ reset ++ " ");
            }
            stderrWrite(item.label);
            stderrWrite("\n");
        }
    }
}

fn multiSelectFallback(allocator: std.mem.Allocator, options: MultiSelectOptions) !MultiSelectResult {
    stderrWrite("  ");
    stderrWrite(options.prompt);
    stderrWrite("\n");
    for (options.items, 0..) |item, i| {
        var buf: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "?";
        stderrWrite("    ");
        stderrWrite(num);
        stderrWrite(". ");
        stderrWrite(item.label);
        stderrWrite("\n");
    }
    stderrWrite("  Enter numbers separated by commas: ");

    var input_buf: [256]u8 = undefined;
    const n = posix.read(std.fs.File.stdin().handle, &input_buf) catch return .cancelled;
    if (n == 0) return .cancelled;

    var line = input_buf[0..n];
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    // Parse comma-separated numbers
    var indices: std.ArrayListUnmanaged(usize) = .empty;
    defer indices.deinit(allocator);

    var iter = std.mem.splitScalar(u8, line, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;
        const num = std.fmt.parseInt(usize, trimmed, 10) catch continue;
        if (num >= 1 and num <= options.items.len) {
            // Check for duplicates
            var dupe = false;
            for (indices.items) |existing| {
                if (existing == num - 1) {
                    dupe = true;
                    break;
                }
            }
            if (!dupe) {
                try indices.append(allocator, num - 1);
            }
        }
    }

    if (indices.items.len == 0) return .cancelled;

    const result = try allocator.dupe(usize, indices.items);
    return .{ .selected = result };
}

// ── Confirm ─────────────────────────────────────────────────────────────

pub const OverwriteAction = enum {
    yes,
    no,
    all,
    diff,
};

pub fn confirmOverwrite(path: []const u8) !OverwriteAction {
    const fd = std.fs.File.stdin().handle;

    if (!posix.isatty(fd)) {
        return confirmOverwriteFallback(path);
    }

    stderrWrite("  " ++ cyan ++ "?" ++ reset ++ " Overwrite " ++ bold);
    stderrWrite(path);
    stderrWrite(reset ++ "? " ++ dim ++ "(yes/No/all/diff)" ++ reset ++ " ");

    var term = try RawTerminal.enter(fd);
    defer term.leave();

    const event = try term.readInputEvent();
    stderrWrite("\n");
    return switch (event) {
        .char => |c| if (c == 'y' or c == 'Y')
            .yes
        else if (c == 'a' or c == 'A')
            .all
        else if (c == 'd' or c == 'D')
            .diff
        else
            .no,
        else => .no,
    };
}

fn confirmOverwriteFallback(path: []const u8) !OverwriteAction {
    stderrWrite("  ? Overwrite ");
    stderrWrite(path);
    stderrWrite("? (yes/No/all/diff) ");

    var buf: [64]u8 = undefined;
    const n = posix.read(std.fs.File.stdin().handle, &buf) catch return .no;
    if (n == 0) return .no;
    if (buf[0] == 'y' or buf[0] == 'Y') return .yes;
    if (buf[0] == 'a' or buf[0] == 'A') return .all;
    if (buf[0] == 'd' or buf[0] == 'D') return .diff;
    return .no;
}

pub fn confirm(prompt: []const u8) !bool {
    const fd = std.fs.File.stdin().handle;

    if (!posix.isatty(fd)) {
        return confirmFallback(prompt);
    }

    stderrWrite("  " ++ cyan ++ "?" ++ reset ++ " " ++ bold);
    stderrWrite(prompt);
    stderrWrite(reset ++ " " ++ dim ++ "(y/N)" ++ reset ++ " ");

    var term = try RawTerminal.enter(fd);
    defer term.leave();

    const event = try term.readInputEvent();
    stderrWrite("\n");
    return switch (event) {
        .char => |c| c == 'y' or c == 'Y',
        else => false,
    };
}

fn confirmFallback(prompt: []const u8) !bool {
    stderrWrite("  ? ");
    stderrWrite(prompt);
    stderrWrite(" (y/N) ");

    var buf: [64]u8 = undefined;
    const n = posix.read(std.fs.File.stdin().handle, &buf) catch return false;
    if (n == 0) return false;
    return buf[0] == 'y' or buf[0] == 'Y';
}

pub const ConfirmAllResult = enum { yes, no, all };

/// Like confirm() but with an additional "all" option: y/N/a
pub fn confirmWithAll(prompt: []const u8) !ConfirmAllResult {
    const fd = std.fs.File.stdin().handle;

    if (!posix.isatty(fd)) {
        return confirmWithAllFallback(prompt);
    }

    stderrWrite("  " ++ cyan ++ "?" ++ reset ++ " " ++ bold);
    stderrWrite(prompt);
    stderrWrite(reset ++ " " ++ dim ++ "(y/N/a)" ++ reset ++ " ");

    var term = try RawTerminal.enter(fd);
    defer term.leave();

    const event = try term.readInputEvent();
    stderrWrite("\n");
    return switch (event) {
        .char => |c| if (c == 'y' or c == 'Y')
            .yes
        else if (c == 'a' or c == 'A')
            .all
        else
            .no,
        else => .no,
    };
}

fn confirmWithAllFallback(prompt: []const u8) !ConfirmAllResult {
    stderrWrite("  ? ");
    stderrWrite(prompt);
    stderrWrite(" (y/N/a) ");

    var buf: [64]u8 = undefined;
    const n = posix.read(std.fs.File.stdin().handle, &buf) catch return .no;
    if (n == 0) return .no;
    if (buf[0] == 'y' or buf[0] == 'Y') return .yes;
    if (buf[0] == 'a' or buf[0] == 'A') return .all;
    return .no;
}

// ── Brain Name Validation ───────────────────────────────────────────────

const reserved_brain_names = [_][]const u8{
    "about",   "activity", "admin",        "analytics", "api", "edit",     "export",
    "history", "import",   "integrations", "members",   "new", "settings", "sharing",
    "stats",
};

pub fn validateBrainName(input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    // Must start with a letter
    if (!std.ascii.isAlphabetic(input[0])) {
        return "must start with a letter";
    }

    // All chars must be alphanumeric, underscore, or hyphen
    for (input[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            return "only letters, numbers, underscores, and hyphens allowed";
        }
    }

    // Min 3 chars
    if (input.len < 3) {
        return "minimum 3 characters";
    }

    // Max 100 chars
    if (input.len > 100) {
        return "maximum 100 characters";
    }

    // Check reserved names (case-insensitive)
    for (&reserved_brain_names) |reserved| {
        if (input.len == reserved.len) {
            var match = true;
            for (input, reserved) |a, b| {
                if (std.ascii.toLower(a) != b) {
                    match = false;
                    break;
                }
            }
            if (match) return "this name is reserved";
        }
    }

    return null; // valid
}
