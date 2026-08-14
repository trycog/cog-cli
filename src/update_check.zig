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
const build_options = @import("build_options");
const debug_log = @import("debug_log.zig");
const fs_util = @import("fs_util.zig");
const paths = @import("paths.zig");
const curl = @import("curl.zig");

/// The running binary's version, sourced from build.zig.zon via build
/// options — the same value mcp.serve logs at startup.
pub const installed_version: []const u8 = build_options.version;

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

// ── Cache file ──────────────────────────────────────────────────────────

/// Cache file basename inside the global config dir (~/.config/cog/).
pub const cache_basename = "update-check.json";
pub const cache_version: u32 = 1;
const max_cache_bytes: usize = 64 * 1024;

/// On-disk schema. Every field has a default so a partial file still loads;
/// tolerance matters more than completeness for an advisory cache.
const CacheSchema = struct {
    version: u32 = 0,
    last_check_unix: i64 = 0,
    latest_version: ?[]const u8 = null,
    last_notified_version: ?[]const u8 = null,
    last_notified_unix: i64 = 0,
};

/// In-memory cache state with owned strings.
const Cache = struct {
    last_check_unix: i64 = 0,
    latest_version: ?[]u8 = null,
    last_notified_version: ?[]u8 = null,
    last_notified_unix: i64 = 0,

    fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        if (self.latest_version) |v| allocator.free(v);
        if (self.last_notified_version) |v| allocator.free(v);
        self.latest_version = null;
        self.last_notified_version = null;
    }
};

/// Load the cache from a directory. Any failure — missing file, malformed
/// JSON, version mismatch, allocation — degrades to "never checked".
fn loadCache(allocator: std.mem.Allocator, dir: std.fs.Dir) Cache {
    const data = dir.readFileAlloc(allocator, cache_basename, max_cache_bytes) catch |err| {
        debug_log.log("update_check.loadCache: unavailable: {s}", .{@errorName(err)});
        return .{};
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(CacheSchema, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        debug_log.log("update_check.loadCache: malformed cache: {s}", .{@errorName(err)});
        return .{};
    };
    defer parsed.deinit();
    if (parsed.value.version != cache_version) {
        debug_log.log("update_check.loadCache: unsupported version={d}", .{parsed.value.version});
        return .{};
    }

    var cache: Cache = .{
        .last_check_unix = parsed.value.last_check_unix,
        .last_notified_unix = parsed.value.last_notified_unix,
    };
    if (parsed.value.latest_version) |v| {
        cache.latest_version = allocator.dupe(u8, v) catch null;
    }
    if (parsed.value.last_notified_version) |v| {
        cache.last_notified_version = allocator.dupe(u8, v) catch null;
    }
    return cache;
}

/// Atomically write the cache as pretty-printed JSON with a trailing newline.
/// Config files are always pretty-printed, never minified. Returns false on
/// failure; callers log and continue — the cache is advisory.
fn writeCache(allocator: std.mem.Allocator, dir: std.fs.Dir, cache: Cache) bool {
    const schema: CacheSchema = .{
        .version = cache_version,
        .last_check_unix = cache.last_check_unix,
        .latest_version = cache.latest_version,
        .last_notified_version = cache.last_notified_version,
        .last_notified_unix = cache.last_notified_unix,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var stringify: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    stringify.write(schema) catch |err| {
        debug_log.log("update_check.writeCache: encode failed: {s}", .{@errorName(err)});
        return false;
    };
    aw.writer.writeByte('\n') catch return false;

    fs_util.writeFileAtomic(dir, allocator, cache_basename, aw.writer.buffered()) catch |err| {
        debug_log.log("update_check.writeCache: write failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

// ── Orchestration ───────────────────────────────────────────────────────

/// An update the caller may want to mention. Both strings are copies owned by
/// the allocator passed to the producing call; release them with `deinit`
/// (or free each field) when done.
pub const NoticeInfo = struct {
    installed: []const u8,
    latest: []const u8,

    pub fn deinit(self: NoticeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.installed);
        allocator.free(self.latest);
    }
};

/// Doctor-facing summary. `update_available` carries an owned NoticeInfo the
/// caller must deinit.
pub const UpdateStatus = union(enum) {
    disabled,
    unknown,
    up_to_date,
    update_available: NoticeInfo,
};

/// Seam for the network poll: returns the latest release version (bare
/// "x.y.z", allocator-owned) or null on any failure. Tests substitute stubs;
/// production uses the curl-backed GitHub fetch.
pub const FetchLatestFn = *const fn (allocator: std.mem.Allocator) ?[]u8;

/// Extract "tag_name" from a GitHub releases/latest response body and
/// normalize it to bare "x.y.z". Null for malformed bodies, missing tags,
/// or tags that are not plain semver — those must never notify.
pub fn parseLatestTag(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    const Release = struct { tag_name: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Release, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        debug_log.log("update_check.parseLatestTag: malformed response: {s}", .{@errorName(err)});
        return null;
    };
    defer parsed.deinit();

    const tag = parsed.value.tag_name;
    if (parseVersion(tag) == null) {
        debug_log.log("update_check.parseLatestTag: unparseable tag_name={s}", .{tag});
        return null;
    }
    const bare = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return allocator.dupe(u8, bare) catch null;
}

/// Poll the release feed if the 24h throttle allows, then persist the
/// attempt. A failed fetch still stamps last_check_unix — a dead network
/// must not be retried on every invocation — and keeps the previously
/// cached latest version.
fn pollIfDue(allocator: std.mem.Allocator, dir: std.fs.Dir, now_unix: i64, fetch: FetchLatestFn) void {
    var cache = loadCache(allocator, dir);
    defer cache.deinit(allocator);

    if (!shouldPoll(now_unix, cache.last_check_unix)) {
        debug_log.log("update_check.pollIfDue: throttled, last_check_unix={d}", .{cache.last_check_unix});
        return;
    }

    debug_log.log("update_check.pollIfDue: polling for the latest release", .{});
    const fetched = fetch(allocator);
    cache.last_check_unix = now_unix;
    if (fetched) |latest| {
        if (cache.latest_version) |old| allocator.free(old);
        cache.latest_version = latest;
        debug_log.log("update_check.pollIfDue: latest={s}", .{latest});
    } else {
        debug_log.log("update_check.pollIfDue: poll failed; keeping cached latest", .{});
    }
    _ = writeCache(allocator, dir, cache);
}

/// Read-only cache evaluation: the notice that is currently due, if any.
fn noticeFromCacheInDir(allocator: std.mem.Allocator, dir: std.fs.Dir, now_unix: i64, installed: []const u8) ?NoticeInfo {
    var cache = loadCache(allocator, dir);
    defer cache.deinit(allocator);

    const latest = cache.latest_version orelse return null;
    if (!shouldNotify(now_unix, installed, latest, cache.last_notified_version, cache.last_notified_unix)) {
        return null;
    }
    return makeNotice(allocator, installed, latest);
}

fn makeNotice(allocator: std.mem.Allocator, installed: []const u8, latest: []const u8) ?NoticeInfo {
    const installed_copy = allocator.dupe(u8, installed) catch return null;
    const latest_copy = allocator.dupe(u8, latest) catch {
        allocator.free(installed_copy);
        return null;
    };
    return .{ .installed = installed_copy, .latest = latest_copy };
}

/// Poll (throttle permitting), update the cache, and report the notice that
/// is now due. Does not record the notification — callers that actually
/// display it confirm via markNotified.
fn checkNowInDir(allocator: std.mem.Allocator, dir: std.fs.Dir, now_unix: i64, installed: []const u8, fetch: FetchLatestFn) ?NoticeInfo {
    pollIfDue(allocator, dir, now_unix, fetch);
    return noticeFromCacheInDir(allocator, dir, now_unix, installed);
}

/// Record that a notice for `latest` was actually shown, starting the 7-day
/// renotify window for that version.
fn markNotifiedInDir(allocator: std.mem.Allocator, dir: std.fs.Dir, now_unix: i64, latest: []const u8) void {
    var cache = loadCache(allocator, dir);
    defer cache.deinit(allocator);

    if (cache.last_notified_version) |old| allocator.free(old);
    cache.last_notified_version = allocator.dupe(u8, latest) catch null;
    cache.last_notified_unix = now_unix;
    if (writeCache(allocator, dir, cache)) {
        debug_log.log("update_check.markNotified: recorded version={s}", .{latest});
    }
}

/// Doctor-grade status: polls synchronously (throttle permitting) and always
/// reports the comparison outcome, ignoring the renotify window — an explicit
/// diagnostic run deserves the unfiltered answer.
fn statusInDir(allocator: std.mem.Allocator, dir: std.fs.Dir, now_unix: i64, installed: []const u8, fetch: FetchLatestFn) UpdateStatus {
    pollIfDue(allocator, dir, now_unix, fetch);

    var cache = loadCache(allocator, dir);
    defer cache.deinit(allocator);
    const latest = cache.latest_version orelse return .unknown;
    const order = compareVersions(latest, installed) orelse return .unknown;
    if (order == .gt) {
        const notice = makeNotice(allocator, installed, latest) orelse return .unknown;
        return .{ .update_available = notice };
    }
    return .up_to_date;
}

/// Format the once-per-session MCP notice. The wording instructs the agent
/// to offer the update to the user — never to apply it on its own.
pub fn formatAgentNotice(allocator: std.mem.Allocator, notice: NoticeInfo) ?[]u8 {
    return std.fmt.allocPrint(
        allocator,
        "NOTE: Cog v{s} is available (installed v{s}). Ask the user before updating; " ++
            "brew upgrade cog or https://github.com/trycog/cog-cli/releases\n\n",
        .{ notice.latest, notice.installed },
    ) catch null;
}

// ── Public API ──────────────────────────────────────────────────────────

const releases_url = "https://api.github.com/repos/trycog/cog-cli/releases/latest";
const max_release_response_bytes: usize = 1024 * 1024;

/// Production fetch: unauthenticated HTTPS GET against the GitHub releases
/// API through src/curl.zig, which enforces HTTPS-only transport, TLS
/// verification, redirect limits, and timeouts. RequestOptions exposes no
/// timeout override, so the module defaults apply; the poll runs in a
/// detached worker, so it never blocks a user-visible operation. The only
/// header is a User-Agent, which the GitHub API requires.
fn fetchLatestTag(allocator: std.mem.Allocator) ?[]u8 {
    curl.globalInit();
    debug_log.log("update_check.fetchLatestTag: GET {s}", .{releases_url});
    const response = curl.getWithOptions(
        allocator,
        releases_url,
        &.{"User-Agent: cog-cli"},
        .{ .max_response_bytes = max_release_response_bytes },
    ) catch |err| {
        debug_log.log("update_check.fetchLatestTag: request failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(response.body);
    if (response.status_code != 200) {
        debug_log.log("update_check.fetchLatestTag: status={d}", .{response.status_code});
        return null;
    }
    return parseLatestTag(allocator, response.body);
}

/// Resolve ~/.config/cog as an open directory. `create` makes the directory
/// when a write may follow; the read-only paths never create anything.
fn openGlobalConfigDir(allocator: std.mem.Allocator, create: bool) ?std.fs.Dir {
    const path = paths.getGlobalConfigDir(allocator) catch |err| {
        debug_log.log("update_check: no global config dir: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(path);
    if (create) {
        std.fs.cwd().makePath(path) catch |err| {
            debug_log.log("update_check: cannot create {s}: {s}", .{ path, @errorName(err) });
            return null;
        };
    }
    return std.fs.openDirAbsolute(path, .{}) catch |err| {
        debug_log.log("update_check: cannot open {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
}

/// True when the COG_UPDATE_CHECK=0 opt-out is set in this process's
/// environment. All public entry points honor it.
pub fn isDisabledByEnv() bool {
    return isOptedOut(std.posix.getenv(OPT_OUT_ENV));
}

/// Poll for the latest release if the 24h throttle allows, update the cache,
/// and return the notice that is due, if any. The returned NoticeInfo is
/// owned by `allocator`; release it with deinit. Displaying callers should
/// confirm via markNotified so the 7-day renotify window starts. Every
/// failure is silent. In test builds this is a no-op: hermetic tests must
/// never reach the network or the user's real config directory — they
/// exercise the *InDir seams instead.
pub fn checkNow(allocator: std.mem.Allocator) ?NoticeInfo {
    if (builtin.is_test) return null;
    if (isDisabledByEnv()) {
        debug_log.log("update_check.checkNow: disabled via {s}=0", .{OPT_OUT_ENV});
        return null;
    }
    var dir = openGlobalConfigDir(allocator, true) orelse return null;
    defer dir.close();
    return checkNowInDir(allocator, dir, std.time.timestamp(), installed_version, fetchLatestTag);
}

/// Read-only cache evaluation — no network, no writes. Same ownership story
/// as checkNow.
pub fn pendingNoticeFromCache(allocator: std.mem.Allocator) ?NoticeInfo {
    if (builtin.is_test) return null;
    if (isDisabledByEnv()) return null;
    var dir = openGlobalConfigDir(allocator, false) orelse return null;
    defer dir.close();
    return noticeFromCacheInDir(allocator, dir, std.time.timestamp(), installed_version);
}

/// Record that a notice for `latest` was actually displayed.
pub fn markNotified(allocator: std.mem.Allocator, latest: []const u8) void {
    if (builtin.is_test) return;
    var dir = openGlobalConfigDir(allocator, true) orelse return;
    defer dir.close();
    markNotifiedInDir(allocator, dir, std.time.timestamp(), latest);
}

/// Synchronous doctor status: polls if the throttle allows (never when opted
/// out), and reports the truth regardless of notification history. An
/// `update_available` result carries an owned NoticeInfo to deinit.
pub fn statusForDoctor(allocator: std.mem.Allocator) UpdateStatus {
    if (isDisabledByEnv()) return .disabled;
    if (builtin.is_test) return .unknown;
    var dir = openGlobalConfigDir(allocator, true) orelse return .unknown;
    defer dir.close();
    return statusInDir(allocator, dir, std.time.timestamp(), installed_version, fetchLatestTag);
}

// ── Tests: orchestration seams ──────────────────────────────────────────

var stub_fetch_calls: usize = 0;

fn stubFetchNewer(allocator: std.mem.Allocator) ?[]u8 {
    stub_fetch_calls += 1;
    return allocator.dupe(u8, "0.27.0") catch null;
}

fn stubFetchFails(allocator: std.mem.Allocator) ?[]u8 {
    _ = allocator;
    stub_fetch_calls += 1;
    return null;
}

test "checkNowInDir polls, caches, and applies the renotify window" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    stub_fetch_calls = 0;

    const now: i64 = 1_755_000_000;
    const first = checkNowInDir(allocator, tmp.dir, now, "0.26.0", stubFetchNewer) orelse
        return error.TestUnexpectedResult;
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("0.26.0", first.installed);
    try std.testing.expectEqualStrings("0.27.0", first.latest);
    try std.testing.expectEqual(@as(usize, 1), stub_fetch_calls);

    var cache = loadCache(allocator, tmp.dir);
    defer cache.deinit(allocator);
    try std.testing.expectEqual(now, cache.last_check_unix);
    try std.testing.expectEqualStrings("0.27.0", cache.latest_version.?);

    // The caller displayed the notice; within the window it stays quiet and
    // the 24h throttle prevents another poll.
    markNotifiedInDir(allocator, tmp.dir, now + 1, "0.27.0");
    try std.testing.expect(checkNowInDir(allocator, tmp.dir, now + 2, "0.26.0", stubFetchNewer) == null);
    try std.testing.expectEqual(@as(usize, 1), stub_fetch_calls);

    // A week later the reminder is due again.
    const again = checkNowInDir(allocator, tmp.dir, now + renotify_interval_seconds + 2, "0.26.0", stubFetchNewer) orelse
        return error.TestUnexpectedResult;
    defer again.deinit(allocator);
    try std.testing.expectEqualStrings("0.27.0", again.latest);
}

test "checkNowInDir records failed polls to honor the throttle" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    stub_fetch_calls = 0;

    const now: i64 = 1_755_000_000;
    try std.testing.expect(checkNowInDir(allocator, tmp.dir, now, "0.26.0", stubFetchFails) == null);
    try std.testing.expectEqual(@as(usize, 1), stub_fetch_calls);

    var cache = loadCache(allocator, tmp.dir);
    defer cache.deinit(allocator);
    try std.testing.expectEqual(now, cache.last_check_unix);
    try std.testing.expect(cache.latest_version == null);

    // Ten seconds later the attempt is throttled — no hammering a dead network.
    try std.testing.expect(checkNowInDir(allocator, tmp.dir, now + 10, "0.26.0", stubFetchFails) == null);
    try std.testing.expectEqual(@as(usize, 1), stub_fetch_calls);
}

test "checkNowInDir keeps the cached latest when a poll fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    stub_fetch_calls = 0;

    const now: i64 = 1_755_000_000;
    try std.testing.expect(writeCache(allocator, tmp.dir, .{
        .last_check_unix = now - poll_interval_seconds,
        .latest_version = @constCast("0.27.0"),
    }));

    // The re-poll fails, but the previously seen latest still notifies.
    const notice = checkNowInDir(allocator, tmp.dir, now, "0.26.0", stubFetchFails) orelse
        return error.TestUnexpectedResult;
    defer notice.deinit(allocator);
    try std.testing.expectEqualStrings("0.27.0", notice.latest);
    try std.testing.expectEqual(@as(usize, 1), stub_fetch_calls);
}

test "noticeFromCacheInDir evaluates without network or mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const now: i64 = 1_755_000_000;
    try std.testing.expect(writeCache(allocator, tmp.dir, .{
        .last_check_unix = now,
        .latest_version = @constCast("0.27.0"),
    }));

    // Read-only: asking twice yields the notice twice.
    for (0..2) |_| {
        const notice = noticeFromCacheInDir(allocator, tmp.dir, now, "0.26.0") orelse
            return error.TestUnexpectedResult;
        defer notice.deinit(allocator);
        try std.testing.expectEqualStrings("0.27.0", notice.latest);
    }

    // Nothing newer, nothing to say.
    try std.testing.expect(noticeFromCacheInDir(allocator, tmp.dir, now, "0.27.0") == null);
    try std.testing.expect(noticeFromCacheInDir(allocator, tmp.dir, now, "0.28.0") == null);
}

test "statusInDir reports doctor-grade truth regardless of notify history" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    stub_fetch_calls = 0;

    const now: i64 = 1_755_000_000;

    // Nothing cached and the poll fails: unknown.
    switch (statusInDir(allocator, tmp.dir, now, "0.26.0", stubFetchFails)) {
        .unknown => {},
        else => return error.TestUnexpectedResult,
    }

    // A later successful poll reports the update even after a notification
    // was recorded — doctor is explicitly asked, so it always tells.
    markNotifiedInDir(allocator, tmp.dir, now, "0.27.0");
    switch (statusInDir(allocator, tmp.dir, now + poll_interval_seconds, "0.26.0", stubFetchNewer)) {
        .update_available => |notice| {
            defer notice.deinit(allocator);
            try std.testing.expectEqualStrings("0.27.0", notice.latest);
            try std.testing.expectEqualStrings("0.26.0", notice.installed);
        },
        else => return error.TestUnexpectedResult,
    }

    switch (statusInDir(allocator, tmp.dir, now + poll_interval_seconds + 1, "0.27.0", stubFetchNewer)) {
        .up_to_date => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parseLatestTag extracts and normalizes tag_name" {
    const allocator = std.testing.allocator;

    const tag = parseLatestTag(allocator, "{\"tag_name\": \"v0.27.0\", \"name\": \"Release\"}") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(tag);
    try std.testing.expectEqualStrings("0.27.0", tag);

    const bare = parseLatestTag(allocator, "{\"tag_name\": \"0.27.0\"}") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("0.27.0", bare);

    try std.testing.expect(parseLatestTag(allocator, "not json") == null);
    try std.testing.expect(parseLatestTag(allocator, "{\"message\": \"rate limited\"}") == null);
    try std.testing.expect(parseLatestTag(allocator, "{\"tag_name\": \"nightly\"}") == null);
}

test "formatAgentNotice instructs the agent to offer, never apply" {
    const allocator = std.testing.allocator;
    const line = formatAgentNotice(allocator, .{ .installed = "0.26.0", .latest = "0.27.0" }) orelse
        return error.TestUnexpectedResult;
    defer allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "NOTE: Cog v0.27.0 is available (installed v0.26.0)."));
    try std.testing.expect(std.mem.indexOf(u8, line, "Ask the user before updating") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "brew upgrade cog") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "https://github.com/trycog/cog-cli/releases") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n\n"));
}

// ── Tests: cache round-trip ─────────────────────────────────────────────

test "cache round-trips through pretty-printed JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cache: Cache = .{
        .last_check_unix = 1_755_000_000,
        .latest_version = try allocator.dupe(u8, "0.27.0"),
        .last_notified_version = try allocator.dupe(u8, "0.27.0"),
        .last_notified_unix = 1_755_000_100,
    };
    defer cache.deinit(allocator);
    try std.testing.expect(writeCache(allocator, tmp.dir, cache));

    // Configuration files are always pretty-printed, never minified.
    const raw = try tmp.dir.readFileAlloc(allocator, cache_basename, 8192);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\n  \"version\": 1") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "\n"));

    var loaded = loadCache(allocator, tmp.dir);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1_755_000_000), loaded.last_check_unix);
    try std.testing.expectEqualStrings("0.27.0", loaded.latest_version.?);
    try std.testing.expectEqualStrings("0.27.0", loaded.last_notified_version.?);
    try std.testing.expectEqual(@as(i64, 1_755_000_100), loaded.last_notified_unix);
}

test "cache write serializes absent versions as null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(writeCache(allocator, tmp.dir, .{ .last_check_unix = 42 }));
    var loaded = loadCache(allocator, tmp.dir);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), loaded.last_check_unix);
    try std.testing.expect(loaded.latest_version == null);
    try std.testing.expect(loaded.last_notified_version == null);
}

test "cache load treats missing, malformed, and mismatched files as never-checked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var missing = loadCache(allocator, tmp.dir);
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), missing.last_check_unix);
    try std.testing.expect(missing.latest_version == null);

    try tmp.dir.writeFile(.{ .sub_path = cache_basename, .data = "{not json" });
    var malformed = loadCache(allocator, tmp.dir);
    defer malformed.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), malformed.last_check_unix);

    try tmp.dir.writeFile(.{ .sub_path = cache_basename, .data = 
        \\{
        \\  "version": 99,
        \\  "last_check_unix": 7
        \\}
    });
    var mismatched = loadCache(allocator, tmp.dir);
    defer mismatched.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 0), mismatched.last_check_unix);

    // Unknown fields and missing optionals are tolerated.
    try tmp.dir.writeFile(.{ .sub_path = cache_basename, .data = 
        \\{
        \\  "version": 1,
        \\  "last_check_unix": 7,
        \\  "future_field": true
        \\}
    });
    var partial = loadCache(allocator, tmp.dir);
    defer partial.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 7), partial.last_check_unix);
    try std.testing.expect(partial.latest_version == null);
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
