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

/// Print the Cog ASCII art header
pub fn header() void {
    stderrWrite("\n" ++ cyan);
    stderrWrite("  " ++ ct ++ h4 ++ "  " ++ ct ++ h3 ++ tr ++ "  " ++ ct ++ h4 ++ "\n");
    stderrWrite("  " ++ vv ++ "      " ++ vv ++ "   " ++ vv ++ "  " ++ vv ++ "\n");
    stderrWrite("  " ++ vv ++ "      " ++ vv ++ "   " ++ vv ++ "  " ++ vv ++ " " ++ hh ++ hh ++ tr ++ "\n");
    stderrWrite("  " ++ cb ++ h4 ++ "  " ++ cb ++ h3 ++ br ++ "  " ++ cb ++ h3 ++ br ++ "\n");
    stderrWrite(reset);
    stderrWrite(dim ++ "  Memory for AI agents\n" ++ reset);
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

fn clearLines(line_count: usize) void {
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

// ── Confirm ─────────────────────────────────────────────────────────────

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

// ── Brain Name Validation ───────────────────────────────────────────────

const reserved_brain_names = [_][]const u8{
    "about", "activity", "admin", "analytics", "api", "edit", "export",
    "history", "import", "integrations", "members", "new", "settings",
    "sharing", "stats",
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
