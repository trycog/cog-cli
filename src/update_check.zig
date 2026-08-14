//! Throttled update check against the GitHub releases API.
//!
//! A hidden `__update-check` worker polls at most once per 24 hours and
//! records what it saw in `~/.config/cog/update-check.json`. Callers surface
//! at most one notice per version per 7-day window, and every failure —
//! network, sandbox, parse, cache write — is silent: debug log only, never an
//! error to the user, never a block on the caller. Setting COG_UPDATE_CHECK=0
//! disables both polling and notices.

const std = @import("std");
const builtin = @import("builtin");

/// Environment variable that disables all polling and notices when set to "0".
pub const OPT_OUT_ENV = "COG_UPDATE_CHECK";

/// Hidden subcommand dispatched by main.zig, mirroring the index sync workers.
pub const UPDATE_CHECK_WORKER_COMMAND = "__update-check";

/// At most one network poll per day keeps the check invisible in normal use.
pub const poll_interval_seconds: i64 = 24 * 60 * 60;

/// A version the user already saw is only re-mentioned after a week.
pub const renotify_interval_seconds: i64 = 7 * 24 * 60 * 60;

/// Opt-out is the literal "0" so future values ("1", "verbose") stay open.
pub fn isOptedOut(env_value: ?[]const u8) bool {
    const value = env_value orelse return false;
    return std.mem.eql(u8, value, "0");
}

pub const Semver = struct {
    major: u64,
    minor: u64,
    patch: u64,
};

/// Parse "x.y.z" with an optional leading "v". Anything else — missing
/// components, extra components, pre-release suffixes — is null: an
/// unparseable version must never produce an update notice.
pub fn parseVersion(text: []const u8) ?Semver {
    const bare = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    var it = std.mem.splitScalar(u8, bare, '.');
    var components: [3]u64 = undefined;
    for (&components) |*component| {
        const part = it.next() orelse return null;
        if (part.len == 0) return null;
        component.* = std.fmt.parseInt(u64, part, 10) catch return null;
    }
    if (it.next() != null) return null;
    return .{ .major = components[0], .minor = components[1], .patch = components[2] };
}

/// Numeric component-wise comparison; null when either side is unparseable.
pub fn compareVersions(a: []const u8, b: []const u8) ?std.math.Order {
    const va = parseVersion(a) orelse return null;
    const vb = parseVersion(b) orelse return null;
    const major = std.math.order(va.major, vb.major);
    if (major != .eq) return major;
    const minor = std.math.order(va.minor, vb.minor);
    if (minor != .eq) return minor;
    return std.math.order(va.patch, vb.patch);
}

/// A poll is due when 24h elapsed since the last one. A stamp in the future
/// means the clock moved backwards; the stamp is untrustworthy, so poll.
pub fn shouldPoll(now_unix: i64, last_check_unix: i64) bool {
    if (last_check_unix <= 0) return true;
    if (now_unix < last_check_unix) return true;
    return now_unix - last_check_unix >= poll_interval_seconds;
}

/// A notice is due only for a strictly newer, parseable version, and only if
/// this exact version was not already mentioned within the renotify window.
/// Clock skew around last_notified_unix suppresses rather than spams.
pub fn shouldNotify(
    now_unix: i64,
    installed: []const u8,
    latest: []const u8,
    last_notified_version: ?[]const u8,
    last_notified_unix: i64,
) bool {
    const order = compareVersions(latest, installed) orelse return false;
    if (order != .gt) return false;
    const notified = last_notified_version orelse return true;
    const same_version = if (compareVersions(notified, latest)) |o| o == .eq else std.mem.eql(u8, notified, latest);
    if (!same_version) return true;
    return now_unix - last_notified_unix >= renotify_interval_seconds;
}

// ── Tests: decision helpers ─────────────────────────────────────────────

test "isOptedOut only honors the literal 0" {
    try std.testing.expect(!isOptedOut(null));
    try std.testing.expect(isOptedOut("0"));
    try std.testing.expect(!isOptedOut("1"));
    try std.testing.expect(!isOptedOut(""));
    try std.testing.expect(!isOptedOut("false"));
}

test "parseVersion accepts x.y.z with an optional leading v" {
    const v = parseVersion("1.2.3") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectEqual(@as(u64, 2), v.minor);
    try std.testing.expectEqual(@as(u64, 3), v.patch);

    const pv = parseVersion("v0.26.0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), pv.major);
    try std.testing.expectEqual(@as(u64, 26), pv.minor);
    try std.testing.expectEqual(@as(u64, 0), pv.patch);
}

test "parseVersion rejects malformed versions" {
    try std.testing.expect(parseVersion("") == null);
    try std.testing.expect(parseVersion("v") == null);
    try std.testing.expect(parseVersion("1.2") == null);
    try std.testing.expect(parseVersion("1.2.3.4") == null);
    try std.testing.expect(parseVersion("abc") == null);
    try std.testing.expect(parseVersion("1.2.x") == null);
    try std.testing.expect(parseVersion("1.2.3-rc1") == null);
    try std.testing.expect(parseVersion("1..3") == null);
    try std.testing.expect(parseVersion("vv1.2.3") == null);
}

test "compareVersions orders numerically component-wise" {
    try std.testing.expectEqual(@as(?std.math.Order, .lt), compareVersions("1.2.3", "1.2.4"));
    try std.testing.expectEqual(@as(?std.math.Order, .gt), compareVersions("2.0.0", "1.99.99"));
    try std.testing.expectEqual(@as(?std.math.Order, .eq), compareVersions("v0.26.0", "0.26.0"));
    // Numeric, not lexicographic: 0.10.0 is newer than 0.9.0.
    try std.testing.expectEqual(@as(?std.math.Order, .gt), compareVersions("0.10.0", "0.9.0"));
    // Unparseable on either side means no comparison at all.
    try std.testing.expect(compareVersions("nightly", "0.26.0") == null);
    try std.testing.expect(compareVersions("0.26.0", "nightly") == null);
}

test "shouldPoll throttles to one poll per 24 hours" {
    const day: i64 = 24 * 60 * 60;
    // Never checked before.
    try std.testing.expect(shouldPoll(1_000_000, 0));
    // Exactly 24h since the last check: due again.
    try std.testing.expect(shouldPoll(1_000_000 + day, 1_000_000));
    // One second short of the window: throttled.
    try std.testing.expect(!shouldPoll(1_000_000 + day - 1, 1_000_000));
    // Clock went backwards: the stamp is untrustworthy, poll again.
    try std.testing.expect(shouldPoll(999_999, 1_000_000));
}

test "shouldNotify requires a strictly newer parseable version" {
    const now: i64 = 1_000_000;
    try std.testing.expect(shouldNotify(now, "0.26.0", "0.27.0", null, 0));
    try std.testing.expect(!shouldNotify(now, "0.26.0", "0.26.0", null, 0));
    try std.testing.expect(!shouldNotify(now, "0.26.0", "0.25.9", null, 0));
    // Unparseable versions never produce a notice.
    try std.testing.expect(!shouldNotify(now, "0.26.0", "nightly", null, 0));
    try std.testing.expect(!shouldNotify(now, "dev", "0.27.0", null, 0));
}

test "shouldNotify renotifies the same version only after 7 days" {
    const week: i64 = 7 * 24 * 60 * 60;
    const notified_at: i64 = 1_000_000;
    // Notified 6 days ago about this exact version: stay quiet.
    try std.testing.expect(!shouldNotify(notified_at + week - 1, "0.26.0", "0.27.0", "0.27.0", notified_at));
    // A full week later the reminder is due again.
    try std.testing.expect(shouldNotify(notified_at + week, "0.26.0", "0.27.0", "0.27.0", notified_at));
    // The v-prefixed spelling is still the same version.
    try std.testing.expect(!shouldNotify(notified_at + 1, "0.26.0", "0.27.0", "v0.27.0", notified_at));
    // A different newer version notifies immediately.
    try std.testing.expect(shouldNotify(notified_at + 1, "0.26.0", "0.28.0", "0.27.0", notified_at));
    // Clock skew (notified in the future) suppresses rather than spams.
    try std.testing.expect(!shouldNotify(notified_at - 10, "0.26.0", "0.27.0", "0.27.0", notified_at));
}
