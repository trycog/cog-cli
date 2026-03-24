const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

/// Global debug log file handle. When null, all log calls are no-ops.
var log_file: ?std.fs.File = null;

/// Serializes concurrent writes so log lines don't interleave.
var log_mutex: std.Thread.Mutex = .{};

pub const ResourceUsage = struct {
    user_ms: i64,
    system_ms: i64,
    max_rss_kb: i64,
    minor_faults: i64,
    major_faults: i64,
    vol_cs: i64,
    invol_cs: i64,
};

/// Initialize debug logging by opening .cog/cog.log in the given cog directory.
/// Truncates the log on each invocation and writes a diagnostic header.
pub fn init(cog_dir: []const u8, version: []const u8, args: []const [:0]const u8) void {
    // Open with truncate so each command gets a fresh log
    var dir = std.fs.openDirAbsolute(cog_dir, .{}) catch return;
    defer dir.close();
    log_file = dir.createFile("cog.log", .{ .truncate = true }) catch return;

    // Install signal handlers to capture crashes
    installSignalHandlers();

    // Write diagnostic header
    log("=== cog debug log ===", .{});
    log("version: {s}", .{version});
    log("os: {s}", .{@tagName(builtin.os.tag)});
    log("arch: {s}", .{@tagName(builtin.cpu.arch)});
    log("zig: {d}.{d}.{d}", .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch });

    // Log the command line
    var cmd_buf: [8192]u8 = undefined;
    var pos: usize = 0;
    for (args) |arg| {
        if (pos > 0) {
            if (pos < cmd_buf.len) {
                cmd_buf[pos] = ' ';
                pos += 1;
            }
        }
        const end = @min(pos + arg.len, cmd_buf.len);
        @memcpy(cmd_buf[pos..end], arg[0 .. end - pos]);
        pos = end;
    }
    log("command: {s}", .{cmd_buf[0..pos]});
}

/// Append client (agent) info to the log header. Called once the MCP
/// initialize handshake supplies clientInfo.
pub fn logClientInfo(agent: ?[]const u8, version: ?[]const u8, model: ?[]const u8) void {
    log("agent: {s}", .{agent orelse "unknown"});
    log("agent_version: {s}", .{version orelse "unknown"});
    log("model: {s}", .{model orelse "unknown"});
    log("---", .{});
}

/// Write the header separator. Use when no MCP client info will follow.
pub fn logHeaderSeparator() void {
    log("---", .{});
}

/// Initialize debug logging by finding .cog directory from cwd.
pub fn initFromCwd(allocator: std.mem.Allocator, version: []const u8, args: []const [:0]const u8) void {
    const paths = @import("paths.zig");
    const cog_dir = paths.findCogDir(allocator) catch {
        // No .cog dir found — try to create one in cwd
        const fallback = paths.findOrCreateCogDir(allocator) catch return;
        defer allocator.free(fallback);
        init(fallback, version, args);
        return;
    };
    defer allocator.free(cog_dir);
    init(cog_dir, version, args);
}

/// Close the debug log file.
pub fn deinit() void {
    if (log_file) |f| {
        log("=== debug logging stopped ===", .{});
        f.close();
    }
    log_file = null;
}

/// Write a timestamped log entry. No-op when debug logging is not enabled.
/// Thread-safe: a mutex serializes writes so concurrent threads don't interleave.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    const f = log_file orelse return;
    log_mutex.lock();
    defer log_mutex.unlock();
    var buf: [128]u8 = undefined;
    const ts = std.time.timestamp();
    const prefix = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
    f.writeAll(prefix) catch return;
    var msg_buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    f.writeAll(msg) catch return;
    f.writeAll("\n") catch return;
}

/// Returns true when debug logging is active.
pub fn enabled() bool {
    return log_file != null;
}

pub fn resourceUsage() ?ResourceUsage {
    if (@TypeOf(std.c.rusage) == void) return null;

    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return null;

    return .{
        .user_ms = @as(i64, @intCast(usage.utime.sec)) * 1000 + @divTrunc(@as(i64, @intCast(usage.utime.usec)), 1000),
        .system_ms = @as(i64, @intCast(usage.stime.sec)) * 1000 + @divTrunc(@as(i64, @intCast(usage.stime.usec)), 1000),
        .max_rss_kb = @as(i64, @intCast(usage.maxrss)),
        .minor_faults = @as(i64, @intCast(usage.minflt)),
        .major_faults = @as(i64, @intCast(usage.majflt)),
        .vol_cs = @as(i64, @intCast(usage.nvcsw)),
        .invol_cs = @as(i64, @intCast(usage.nivcsw)),
    };
}

pub fn logResourceUsage(context: []const u8) void {
    const usage = resourceUsage() orelse return;
    log(
        "{s} rss_kb={d} user_ms={d} sys_ms={d} minflt={d} majflt={d} nvcsw={d} nivcsw={d}",
        .{ context, usage.max_rss_kb, usage.user_ms, usage.system_ms, usage.minor_faults, usage.major_faults, usage.vol_cs, usage.invol_cs },
    );
}

/// Install signal handlers for crash signals (SIGILL, SIGSEGV, SIGBUS, SIGABRT).
fn installSignalHandlers() void {
    const signals = [_]u8{
        posix.SIG.ILL,
        posix.SIG.SEGV,
        posix.SIG.BUS,
        posix.SIG.ABRT,
    };
    for (signals) |sig| {
        const handler = posix.Sigaction{
            .handler = .{ .sigaction = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = c.SA.SIGINFO | c.SA.RESETHAND,
        };
        posix.sigaction(sig, &handler, null);
    }
}

fn signalHandler(sig: i32, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const sig_name: []const u8 = switch (sig) {
        posix.SIG.ILL => "SIGILL (Illegal instruction)",
        posix.SIG.SEGV => "SIGSEGV (Segmentation fault)",
        posix.SIG.BUS => "SIGBUS (Bus error)",
        posix.SIG.ABRT => "SIGABRT (Abort)",
        else => "Unknown signal",
    };

    const f = log_file orelse return;

    // Write crash header
    var hdr_buf: [256]u8 = undefined;
    const ts = std.time.timestamp();
    const hdr = std.fmt.bufPrint(&hdr_buf, "\n[{d}] === CRASH: {s} ===\n", .{ ts, sig_name }) catch return;
    f.writeAll(hdr) catch return;

    // Dump stack trace (return addresses)
    var addr_buf: [128]u8 = undefined;
    var stack_iter = std.debug.StackIterator.init(null, null);
    var frame_num: usize = 0;
    while (stack_iter.next()) |addr| {
        const line = std.fmt.bufPrint(&addr_buf, "  frame {d}: 0x{x}\n", .{ frame_num, addr }) catch break;
        f.writeAll(line) catch break;
        frame_num += 1;
        if (frame_num > 64) break;
    }

    f.writeAll("=== end crash ===\n") catch {};
}

test "debug_log disabled by default" {
    try std.testing.expect(!enabled());
    // Calling log when disabled should be a safe no-op
    log("this should not crash", .{});
}
