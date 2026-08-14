//! Credential-boundary URL parsing and global approved-origin persistence.

const std = @import("std");
const builtin = @import("builtin");
const debug_log = if (builtin.os.tag == .windows) struct {
    pub fn log(comptime format: []const u8, args: anytype) void {
        _ = format;
        _ = args;
    }
} else @import("debug_log.zig");
const paths = if (builtin.os.tag == .windows) struct {} else @import("paths.zig");

const posix = std.posix;
const default_https_port: u16 = 443;
const lock_file_name = ".approved-origins.lock";

pub const store_file_name = "approved-origins.json";
pub const max_store_bytes: usize = 64 * 1024;
pub const max_origins: usize = 256;
pub const max_url_bytes: usize = 4096;

/// A canonical HTTPS origin. `serialized` is owned by the value.
pub const Origin = struct {
    serialized: []u8,
    is_official: bool,

    pub fn deinit(self: *Origin, allocator: std.mem.Allocator) void {
        allocator.free(self.serialized);
        self.* = undefined;
    }
};

/// A canonical credential-bearing brain URL with exactly two path segments.
pub const BrainUrl = struct {
    origin: Origin,
    first_segment: []u8,
    second_segment: []u8,

    pub fn deinit(self: *BrainUrl, allocator: std.mem.Allocator) void {
        self.origin.deinit(allocator);
        allocator.free(self.first_segment);
        allocator.free(self.second_segment);
        self.* = undefined;
    }
};

const Authority = struct {
    host: []const u8,
    port: u16,
    is_ipv6: bool,
};

const UrlParts = struct {
    authority: Authority,
    path: []const u8,
};

/// Parse and canonicalize an HTTPS origin. The input must contain no path other
/// than an optional trailing slash, and no query, fragment, or userinfo.
pub fn parseOrigin(allocator: std.mem.Allocator, input: []const u8) !Origin {
    const parts = parseUrlParts(input) catch |err| {
        debug_log.log("credential_boundary.parseOrigin: rejected input: {s}", .{@errorName(err)});
        return err;
    };
    if (parts.path.len > 1) {
        debug_log.log("credential_boundary.parseOrigin: rejected path-bearing origin", .{});
        return error.PathNotAllowed;
    }

    const origin = try canonicalOrigin(allocator, parts.authority);
    debug_log.log("credential_boundary.parseOrigin: accepted canonical origin official={any}", .{origin.is_official});
    return origin;
}

/// Parse and canonicalize a credential-bearing brain URL with exactly two
/// non-empty path segments.
pub fn parseBrainUrl(allocator: std.mem.Allocator, input: []const u8) !BrainUrl {
    const parts = parseUrlParts(input) catch |err| {
        debug_log.log("credential_boundary.parseBrainUrl: rejected input: {s}", .{@errorName(err)});
        return err;
    };
    if (parts.path.len < 4 or parts.path[0] != '/') return error.InvalidBrainPath;
    const segments = parts.path[1..];
    const slash = std.mem.indexOfScalar(u8, segments, '/') orelse return error.InvalidBrainPath;
    if (slash == 0 or slash + 1 >= segments.len or std.mem.indexOfScalar(u8, segments[slash + 1 ..], '/') != null) {
        debug_log.log("credential_boundary.parseBrainUrl: rejected invalid brain path shape", .{});
        return error.InvalidBrainPath;
    }
    const first_segment = segments[0..slash];
    const second_segment = segments[slash + 1 ..];
    if (isDotSegment(first_segment) or isDotSegment(second_segment) or
        std.mem.indexOfScalar(u8, first_segment, '%') != null or
        std.mem.indexOfScalar(u8, second_segment, '%') != null)
    {
        debug_log.log("credential_boundary.parseBrainUrl: rejected ambiguous brain path segment", .{});
        return error.InvalidBrainPath;
    }

    var origin = try canonicalOrigin(allocator, parts.authority);
    errdefer origin.deinit(allocator);
    if (origin.serialized.len + 1 + first_segment.len + 1 + second_segment.len > max_url_bytes) {
        return error.UrlTooLong;
    }
    const first = try allocator.dupe(u8, first_segment);
    errdefer allocator.free(first);
    const second = try allocator.dupe(u8, second_segment);
    errdefer allocator.free(second);
    debug_log.log("credential_boundary.parseBrainUrl: accepted official={any}", .{origin.is_official});
    return .{ .origin = origin, .first_segment = first, .second_segment = second };
}

fn isDotSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..");
}

fn parseUrlParts(input: []const u8) !UrlParts {
    if (input.len > max_url_bytes) return error.UrlTooLong;
    if (!std.mem.startsWith(u8, input, "https://")) return error.HttpsRequired;
    if (input.len == "https://".len) return error.MissingHost;

    for (input) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidCharacter;
    }
    if (std.mem.indexOfScalar(u8, input, '?') != null) return error.QueryNotAllowed;
    if (std.mem.indexOfScalar(u8, input, '#') != null) return error.FragmentNotAllowed;

    const remainder = input["https://".len..];
    const path_start = std.mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const authority_text = remainder[0..path_start];
    if (authority_text.len == 0) return error.MissingHost;
    if (std.mem.indexOfScalar(u8, authority_text, '@') != null) return error.UserinfoNotAllowed;

    const authority = try parseAuthority(authority_text);
    return .{
        .authority = authority,
        .path = if (path_start < remainder.len) remainder[path_start..] else "",
    };
}

fn parseAuthority(input: []const u8) !Authority {
    if (input[0] == '[') {
        const close = std.mem.indexOfScalar(u8, input, ']') orelse return error.InvalidHost;
        const host = input[1..close];
        if (host.len == 0 or std.mem.indexOfScalar(u8, host, '%') != null) return error.InvalidHost;
        _ = std.net.Ip6Address.parse(host, 0) catch return error.InvalidHost;

        var port: u16 = default_https_port;
        if (close + 1 < input.len) {
            if (input[close + 1] != ':') return error.InvalidHost;
            port = try parsePort(input[close + 2 ..]);
        }
        return .{ .host = host, .port = port, .is_ipv6 = true };
    }

    if (std.mem.indexOfScalar(u8, input, '[') != null or std.mem.indexOfScalar(u8, input, ']') != null) {
        return error.InvalidHost;
    }
    const colon = std.mem.lastIndexOfScalar(u8, input, ':');
    const host = if (colon) |index| input[0..index] else input;
    if (host.len == 0) return error.MissingHost;
    if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidHost;
    try validateDomainHost(host);
    if (isAmbiguousNumericHost(host)) return error.InvalidHost;

    return .{
        .host = host,
        .port = if (colon) |index| try parsePort(input[index + 1 ..]) else default_https_port,
        .is_ipv6 = false,
    };
}

fn parsePort(input: []const u8) !u16 {
    if (input.len == 0) return error.InvalidPort;
    for (input) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidPort;
    }
    const port = std.fmt.parseInt(u16, input, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn isAmbiguousNumericHost(host: []const u8) bool {
    var saw_numeric_component = false;
    var component_start: usize = 0;
    var index: usize = 0;
    while (index <= host.len) : (index += 1) {
        if (index < host.len and host[index] != '.') continue;
        const component = host[component_start..index];
        if (component.len == 0) return false;
        if (!isLegacyNumericComponent(component)) return false;
        saw_numeric_component = true;
        component_start = index + 1;
    }
    if (!saw_numeric_component) return false;

    // Accept only strict canonical dotted-decimal. Reject integer, hexadecimal,
    // octal-looking, shortened, and mixed-radix forms accepted by libcurl.
    _ = std.net.Ip4Address.parse(host, 0) catch return true;
    return false;
}

fn isLegacyNumericComponent(component: []const u8) bool {
    if (component.len >= 2 and component[0] == '0' and (component[1] == 'x' or component[1] == 'X')) {
        for (component[2..]) |byte| {
            if (!std.ascii.isHex(byte)) return false;
        }
        return true;
    }
    for (component) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn validateDomainHost(host: []const u8) !void {
    if (host[0] == '.' or host[host.len - 1] == '.') return error.InvalidHost;
    var label_len: usize = 0;
    var label_starts_with_hyphen = false;
    for (host, 0..) |byte, index| {
        if (byte == '.') {
            if (label_len == 0 or label_starts_with_hyphen or host[index - 1] == '-') return error.InvalidHost;
            label_len = 0;
            label_starts_with_hyphen = false;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidHost;
        if (label_len == 0) label_starts_with_hyphen = byte == '-';
        label_len += 1;
        if (label_len > 63) return error.InvalidHost;
    }
    if (label_len == 0 or label_starts_with_hyphen or host[host.len - 1] == '-') return error.InvalidHost;
}

fn canonicalOrigin(allocator: std.mem.Allocator, authority: Authority) !Origin {
    const serialized = try serializeOrigin(allocator, authority);
    errdefer allocator.free(serialized);
    if (serialized.len > max_url_bytes) return error.UrlTooLong;
    return .{
        .serialized = serialized,
        .is_official = std.mem.eql(u8, serialized, "https://trycog.ai:443"),
    };
}

fn serializeOrigin(allocator: std.mem.Allocator, authority: Authority) ![]u8 {
    if (!authority.is_ipv6) {
        const result = try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ authority.host, authority.port });
        for (result["https://".len..]) |*byte| {
            if (byte.* == ':') break;
            byte.* = std.ascii.toLower(byte.*);
        }
        return result;
    }

    const address = std.net.Ip6Address.parse(authority.host, authority.port) catch return error.InvalidHost;
    return std.fmt.allocPrint(allocator, "https://{f}", .{address});
}

const Store = struct {
    origins: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.origins.items) |origin| allocator.free(origin);
        self.origins.deinit(allocator);
        self.* = undefined;
    }

    fn contains(self: *const Store, origin: []const u8) bool {
        for (self.origins.items) |candidate| {
            if (std.mem.eql(u8, candidate, origin)) return true;
        }
        return false;
    }
};

const PersistedStore = struct {
    version: u32,
    origins: []const []const u8,
};

/// Return whether an exact canonical origin is present in the global store.
/// Windows returns `error.UnsupportedPlatform` because Zig 0.15 cannot provide
/// reparse-point-resistant file access for this security state.
pub fn isApproved(allocator: std.mem.Allocator, input: []const u8) !bool {
    var origin = try parseOrigin(allocator, input);
    defer origin.deinit(allocator);
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    return isApprovedGlobal(allocator, origin.serialized);
}

fn isApprovedGlobal(allocator: std.mem.Allocator, canonical_origin: []const u8) !bool {
    const config_dir_path = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir_path);
    debug_log.log("credential_boundary.isApproved: resolving global approved-origin store", .{});

    var config_dir = openValidatedConfigDir(config_dir_path, false) catch |err| switch (err) {
        error.FileNotFound => {
            debug_log.log("credential_boundary.isApproved: global store directory missing", .{});
            return false;
        },
        else => return err,
    };
    defer config_dir.close();
    return isCanonicalOriginApprovedInDir(config_dir, allocator, canonical_origin);
}

/// Add an origin to the global store. Returns true when a new origin was added.
/// Windows returns `error.UnsupportedPlatform`; approval storage fails closed.
pub fn approve(allocator: std.mem.Allocator, input: []const u8) !bool {
    var origin = try parseOrigin(allocator, input);
    defer origin.deinit(allocator);
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    return approveGlobal(allocator, origin.serialized);
}

fn approveGlobal(allocator: std.mem.Allocator, canonical_origin: []const u8) !bool {
    const config_dir_path = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir_path);
    debug_log.log("credential_boundary.approve: ensuring global approved-origin directory", .{});
    var config_dir = try openValidatedConfigDir(config_dir_path, true);
    defer config_dir.close();
    return approveCanonicalOriginInDir(config_dir, allocator, canonical_origin);
}

fn isApprovedInDir(dir: std.fs.Dir, allocator: std.mem.Allocator, input: []const u8) !bool {
    var origin = try parseOrigin(allocator, input);
    defer origin.deinit(allocator);
    return isCanonicalOriginApprovedInDir(dir, allocator, origin.serialized);
}

fn isCanonicalOriginApprovedInDir(dir: std.fs.Dir, allocator: std.mem.Allocator, canonical_origin: []const u8) !bool {
    var store = try loadStore(dir, allocator);
    defer store.deinit(allocator);
    const approved = store.contains(canonical_origin);
    debug_log.log("credential_boundary.isApproved: exact-origin result={any}", .{approved});
    return approved;
}

fn approveInDir(dir: std.fs.Dir, allocator: std.mem.Allocator, input: []const u8) !bool {
    var origin = try parseOrigin(allocator, input);
    defer origin.deinit(allocator);
    return approveCanonicalOriginInDir(dir, allocator, origin.serialized);
}

fn approveCanonicalOriginInDir(dir: std.fs.Dir, allocator: std.mem.Allocator, canonical_origin: []const u8) !bool {
    debug_log.log("credential_boundary.approve: acquiring global store lock", .{});
    var lock_file = acquireStoreLock(dir) catch |err| {
        debug_log.log("credential_boundary.approve: lock acquisition failed: {s}", .{@errorName(err)});
        return error.UnreadableStore;
    };
    defer lock_file.close();

    var store = try loadStore(dir, allocator);
    defer store.deinit(allocator);
    if (store.contains(canonical_origin)) {
        debug_log.log("credential_boundary.approve: canonical origin already approved", .{});
        return false;
    }
    if (store.origins.items.len >= max_origins) return error.TooManyOrigins;

    try appendOriginCopy(&store, allocator, canonical_origin);
    sortOrigins(store.origins.items);
    try persistStore(dir, allocator, &store);
    debug_log.log("credential_boundary.approve: persisted canonical origin count={d}", .{store.origins.items.len});
    return true;
}

fn appendOriginCopy(store: *Store, allocator: std.mem.Allocator, origin: []const u8) !void {
    const copy = try allocator.dupe(u8, origin);
    store.origins.append(allocator, copy) catch |err| {
        allocator.free(copy);
        return err;
    };
}

fn loadStore(dir: std.fs.Dir, allocator: std.mem.Allocator) !Store {
    var store: Store = .{};
    errdefer store.deinit(allocator);

    const maybe_file = openPrivateFileNoFollow(dir, store_file_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => {
            debug_log.log("credential_boundary.loadStore: store missing; using empty approvals", .{});
            return store;
        },
        else => {
            debug_log.log("credential_boundary.loadStore: unreadable store: {s}", .{@errorName(err)});
            return error.UnreadableStore;
        },
    };
    const file = maybe_file;
    defer file.close();
    const stat = file.stat() catch return error.UnreadableStore;
    if (stat.kind != .file) return error.UnreadableStore;
    if (stat.size > max_store_bytes) return error.StoreTooLarge;

    const body = file.readToEndAlloc(allocator, max_store_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileTooBig => return error.StoreTooLarge,
        else => return error.UnreadableStore,
    };
    defer allocator.free(body);
    var parsed = std.json.parseFromSlice(PersistedStore, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_log.log("credential_boundary.loadStore: malformed JSON", .{});
            return error.MalformedStore;
        },
    };
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.origins.len > max_origins) return error.MalformedStore;

    for (parsed.value.origins) |stored| {
        if (stored.len > max_url_bytes) return error.MalformedStore;
        var canonical = parseOrigin(allocator, stored) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedStore,
        };
        defer canonical.deinit(allocator);
        if (!std.mem.eql(u8, stored, canonical.serialized)) return error.MalformedStore;
        if (store.contains(stored)) return error.MalformedStore;
        try appendOriginCopy(&store, allocator, stored);
    }
    sortOrigins(store.origins.items);
    debug_log.log("credential_boundary.loadStore: loaded canonical origin count={d}", .{store.origins.items.len});
    return store;
}

fn persistStore(dir: std.fs.Dir, allocator: std.mem.Allocator, store: *const Store) !void {
    var persisted: std.io.Writer.Allocating = .init(allocator);
    defer persisted.deinit();
    try persisted.writer.writeAll("{\n  \"version\": 1,\n  \"origins\": [\n");
    for (store.origins.items, 0..) |origin, index| {
        try persisted.writer.writeAll("    ");
        try std.json.Stringify.encodeJsonString(origin, .{}, &persisted.writer);
        try persisted.writer.writeAll(if (index + 1 < store.origins.items.len) ",\n" else "\n");
    }
    try persisted.writer.writeAll("  ]\n}\n");
    if (persisted.written().len > max_store_bytes) return error.StoreTooLarge;

    debug_log.log("credential_boundary.persistStore: atomically replacing global store", .{});
    try writePrivateFileAtomic(dir, allocator, store_file_name, persisted.written());
}

fn sortOrigins(origins: [][]u8) void {
    std.mem.sort([]u8, origins, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
}

fn acquireStoreLock(dir: std.fs.Dir) anyerror!std.fs.File {
    if (builtin.os.tag == .windows) {
        debug_log.log("credential_boundary.acquireStoreLock: unsupported no-follow semantics on Windows", .{});
        return error.UnsupportedPlatform;
    }

    var flags: posix.O = .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    const fd = try posix.openat(dir.fd, lock_file_name, flags, 0o600);
    errdefer posix.close(fd);
    try posix.flock(fd, posix.LOCK.EX);
    const file: std.fs.File = .{ .handle = fd };
    try validatePrivateRegularFile(file);
    return file;
}

fn openPrivateFileNoFollow(dir: std.fs.Dir, name: []const u8, mode: std.fs.File.OpenMode) anyerror!std.fs.File {
    if (builtin.os.tag == .windows) {
        debug_log.log("credential_boundary.openPrivateFileNoFollow: unsupported no-follow semantics on Windows", .{});
        return error.UnsupportedPlatform;
    }

    var flags: posix.O = .{
        .ACCMODE = switch (mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = true,
    };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    const fd = try posix.openat(dir.fd, name, flags, 0);
    errdefer posix.close(fd);
    const file: std.fs.File = .{ .handle = fd };
    try validatePrivateRegularFile(file);
    return file;
}

fn validatePrivateRegularFile(file: std.fs.File) !void {
    const stat = try file.stat();
    if (stat.kind != .file) return error.UnreadableStore;
    if (builtin.os.tag != .windows) {
        const posix_stat = try posix.fstat(file.handle);
        if (posix_stat.uid != posix.geteuid()) return error.StoreWrongOwner;
        if (stat.mode & 0o077 != 0) return error.StorePermissionsTooOpen;
    }
}

fn syncStoreDirectory(dir: std.fs.Dir) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    try posix.fsync(dir.fd);
}

fn writePrivateFileAtomic(dir: std.fs.Dir, allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
    return writePrivateFileAtomicWithSync(dir, allocator, name, data, syncStoreDirectory);
}

fn writePrivateFileAtomicWithSync(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    name: []const u8,
    data: []const u8,
    comptime sync_directory: fn (std.fs.Dir) anyerror!void,
) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    var temp = try createPrivateTempFile(dir, allocator, name);
    defer allocator.free(temp.name);
    var renamed = false;
    defer {
        temp.file.close();
        if (!renamed) dir.deleteFile(temp.name) catch |err| {
            debug_log.log("credential_boundary.writePrivateFileAtomic: temp cleanup failed: {s}", .{@errorName(err)});
        };
    }

    try temp.file.writeAll(data);
    try temp.file.sync();
    try dir.rename(temp.name, name);
    renamed = true;
    sync_directory(dir) catch |err| {
        debug_log.log("credential_boundary.writePrivateFileAtomic: store committed but directory sync failed: {s}", .{@errorName(err)});
        return error.StoreCommittedDurabilityUncertain;
    };
}

fn createPrivateTempFile(dir: std.fs.Dir, allocator: std.mem.Allocator, name: []const u8) !struct { name: []u8, file: std.fs.File } {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const temp_name = try std.fmt.allocPrint(allocator, ".{s}.tmp-{d}-{d}", .{ name, std.time.nanoTimestamp(), attempt });
        const file = dir.createFile(temp_name, .{ .exclusive = true, .mode = 0o600 }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(temp_name);
                continue;
            },
            else => {
                allocator.free(temp_name);
                return err;
            },
        };
        if (builtin.os.tag != .windows) {
            file.chmod(0o600) catch |err| {
                file.close();
                dir.deleteFile(temp_name) catch |cleanup_err| {
                    debug_log.log("credential_boundary.createPrivateTempFile: cleanup failed: {s}", .{@errorName(cleanup_err)});
                };
                allocator.free(temp_name);
                return err;
            };
        }
        return .{ .name = temp_name, .file = file };
    }
    return error.TempFileAttemptsExceeded;
}

fn openValidatedConfigDir(path: []const u8, create: bool) !std.fs.Dir {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    if (!std.fs.path.isAbsolute(path)) return error.InvalidConfigPath;
    if (create) {
        debug_log.log("credential_boundary.openValidatedConfigDir: creating global config directory", .{});
        std.fs.cwd().makePath(path) catch |err| {
            debug_log.log("credential_boundary.openValidatedConfigDir: create failed: {s}", .{@errorName(err)});
            return error.UnreadableStore;
        };
    }

    var dir = std.fs.openDirAbsolute(path, .{ .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => {
            debug_log.log("credential_boundary.openValidatedConfigDir: open failed: {s}", .{@errorName(err)});
            return error.UnreadableStore;
        },
    };
    errdefer dir.close();

    const stat = posix.fstat(dir.fd) catch return error.UnreadableStore;
    if (stat.mode & posix.S.IFMT != posix.S.IFDIR) return error.UnreadableStore;
    if (stat.uid != posix.geteuid()) return error.ConfigDirWrongOwner;
    if (stat.mode & 0o077 != 0) {
        if (!create) return error.ConfigDirPermissionsTooOpen;
        debug_log.log("credential_boundary.openValidatedConfigDir: restricting global config directory", .{});
        dir.chmod(0o700) catch return error.UnreadableStore;
    }
    return dir;
}

fn expectOrigin(input: []const u8, expected: []const u8, official: bool) !void {
    var origin = try parseOrigin(std.testing.allocator, input);
    defer origin.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, origin.serialized);
    try std.testing.expectEqual(official, origin.is_official);
}

fn expectBrain(input: []const u8, expected_origin: []const u8, first: []const u8, second: []const u8) !void {
    var brain = try parseBrainUrl(std.testing.allocator, input);
    defer brain.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected_origin, brain.origin.serialized);
    try std.testing.expectEqualStrings(first, brain.first_segment);
    try std.testing.expectEqualStrings(second, brain.second_segment);
}

test "parseOrigin canonicalizes host case and the default HTTPS port" {
    try expectOrigin("https://TRYCOG.AI", "https://trycog.ai:443", true);
    try expectOrigin("https://trycog.ai:443", "https://trycog.ai:443", true);
    try expectOrigin("https://TryCog.Ai:0443", "https://trycog.ai:443", true);
    try expectOrigin("https://trycog.ai:444", "https://trycog.ai:444", false);
}

test "parseOrigin preserves explicit non-default port identity" {
    try expectOrigin("https://EXAMPLE.com", "https://example.com:443", false);
    try expectOrigin("https://EXAMPLE.com:8443", "https://example.com:8443", false);
}

test "parseOrigin accepts a trailing slash only" {
    try expectOrigin("https://example.com/", "https://example.com:443", false);
    try std.testing.expectError(error.PathNotAllowed, parseOrigin(std.testing.allocator, "https://example.com/a"));
}

test "parseOrigin rejects canonical output beyond the URL limit" {
    const input = "https://" ++ ("a." ** 2043) ++ "aa";
    try std.testing.expectEqual(max_url_bytes, input.len);
    try std.testing.expectError(error.UrlTooLong, parseOrigin(std.testing.allocator, input));
}

test "parseOrigin supports canonical IPv6 literals" {
    try expectOrigin("https://[2001:0DB8:0:0:0:0:0:1]", "https://[2001:db8::1]:443", false);
    try expectOrigin("https://[::1]:8443", "https://[::1]:8443", false);
}

test "parsers reject non-HTTPS, userinfo, query, and fragment" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.HttpsRequired, parseOrigin(allocator, "http://example.com"));
    try std.testing.expectError(error.UserinfoNotAllowed, parseOrigin(allocator, "https://user@example.com"));
    try std.testing.expectError(error.QueryNotAllowed, parseOrigin(allocator, "https://example.com?token=secret"));
    try std.testing.expectError(error.FragmentNotAllowed, parseOrigin(allocator, "https://example.com#fragment"));
    try std.testing.expectError(error.UserinfoNotAllowed, parseBrainUrl(allocator, "https://user:pass@example.com/owner/brain"));
    try std.testing.expectError(error.QueryNotAllowed, parseBrainUrl(allocator, "https://example.com/owner/brain?token=secret"));
    try std.testing.expectError(error.FragmentNotAllowed, parseBrainUrl(allocator, "https://example.com/owner/brain#fragment"));
}

test "parsers reject malformed authorities" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingHost, parseOrigin(allocator, "https://"));
    try std.testing.expectError(error.InvalidPort, parseOrigin(allocator, "https://example.com:"));
    try std.testing.expectError(error.InvalidPort, parseOrigin(allocator, "https://example.com:0"));
    try std.testing.expectError(error.InvalidPort, parseOrigin(allocator, "https://example.com:65536"));
    try std.testing.expectError(error.InvalidPort, parseOrigin(allocator, "https://example.com:+443"));
    try std.testing.expectError(error.InvalidPort, parseOrigin(allocator, "https://example.com:4_43"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://2001:db8::1"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://[2001:db8:::1]"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://[fe80::1%1]"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://2130706433"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://0177.0.0.1"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://0x7f000001"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://0x7f.0.0.1"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://0x.0.0.1"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://0X.0.0.1"));
    try std.testing.expectError(error.InvalidHost, parseOrigin(allocator, "https://127.1"));
    try expectOrigin("https://127.0.0.1", "https://127.0.0.1:443", false);
    try std.testing.expectError(error.InvalidCharacter, parseOrigin(allocator, "https://example.com\\owner"));
    try std.testing.expectError(error.InvalidCharacter, parseOrigin(allocator, "https://example.com owner"));
}

test "parseBrainUrl requires exactly two non-empty path segments" {
    try expectBrain("https://EXAMPLE.com/owner/brain", "https://example.com:443", "owner", "brain");
    try expectBrain("https://[::1]:8443/owner/brain", "https://[::1]:8443", "owner", "brain");

    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com//brain"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/brain/extra"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/./brain"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/.."));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/%2e/brain"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/.%2e"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/%2E%2e/brain"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner%2Fother/brain"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/%5cbrain"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/%62rain/name"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/%"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/%2"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/%GG"));
    try std.testing.expectError(error.InvalidBrainPath, parseBrainUrl(allocator, "https://example.com/owner/%252Fbrain"));
}

test "parseBrainUrl rejects oversized input" {
    const input = "https://example.com/" ++ ("a" ** max_url_bytes) ++ "/brain";
    try std.testing.expectError(error.UrlTooLong, parseBrainUrl(std.testing.allocator, input));
}

test "parseBrainUrl rejects canonical representation beyond the URL limit" {
    const input = "https://example.com/" ++ ("a" ** 4074) ++ "/b";
    try std.testing.expectEqual(max_url_bytes, input.len);
    try std.testing.expectError(error.UrlTooLong, parseBrainUrl(std.testing.allocator, input));
}

test "approved origin store defaults missing to empty and checks exact origins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(!try isApprovedInDir(tmp.dir, allocator, "https://example.com"));
    try std.testing.expect(try approveInDir(tmp.dir, allocator, "https://EXAMPLE.com:443"));
    try std.testing.expect(!try approveInDir(tmp.dir, allocator, "https://example.com"));
    try std.testing.expect(try isApprovedInDir(tmp.dir, allocator, "https://example.com:443"));
    try std.testing.expect(!try isApprovedInDir(tmp.dir, allocator, "https://example.com:8443"));
}

fn appendOriginAllocationFailures(allocator: std.mem.Allocator) !void {
    var store: Store = .{};
    defer store.deinit(allocator);
    try appendOriginCopy(&store, allocator, "https://example.com:443");
}

test "approved origin store does not leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, appendOriginAllocationFailures, .{});
}

test "approved origin store persists canonical sorted deduplicated pretty JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(try approveInDir(tmp.dir, allocator, "https://ZETA.example"));
    try std.testing.expect(try approveInDir(tmp.dir, allocator, "https://alpha.example:8443"));
    try std.testing.expect(!try approveInDir(tmp.dir, allocator, "https://zeta.EXAMPLE:0443"));

    const body = try tmp.dir.readFileAlloc(allocator, store_file_name, max_store_bytes);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "origins": [
        \\    "https://alpha.example:8443",
        \\    "https://zeta.example:443"
        \\  ]
        \\}
        \\
    , body);
}

test "approved origin store distinguishes malformed oversized and unreadable state" {
    const allocator = std.testing.allocator;

    var malformed = std.testing.tmpDir(.{});
    defer malformed.cleanup();
    var malformed_file = try malformed.dir.createFile(store_file_name, .{ .mode = 0o600 });
    try malformed_file.writeAll("{not-json}\n");
    malformed_file.close();
    try std.testing.expectError(error.MalformedStore, isApprovedInDir(malformed.dir, allocator, "https://example.com"));

    var oversized = std.testing.tmpDir(.{});
    defer oversized.cleanup();
    var oversized_file = try oversized.dir.createFile(store_file_name, .{ .mode = 0o600 });
    try oversized_file.setEndPos(max_store_bytes + 1);
    oversized_file.close();
    try std.testing.expectError(error.StoreTooLarge, isApprovedInDir(oversized.dir, allocator, "https://example.com"));

    var unreadable = std.testing.tmpDir(.{});
    defer unreadable.cleanup();
    try unreadable.dir.makeDir(store_file_name);
    try std.testing.expectError(error.UnreadableStore, isApprovedInDir(unreadable.dir, allocator, "https://example.com"));
}

test "approved origin store rejects noncanonical and invalid stored origins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var invalid_file = try tmp.dir.createFile(store_file_name, .{ .mode = 0o600 });
    try invalid_file.writeAll(
        \\{
        \\  "version": 1,
        \\  "origins": ["https://EXAMPLE.com"]
        \\}
        \\
    );
    invalid_file.close();
    try std.testing.expectError(error.MalformedStore, isApprovedInDir(tmp.dir, allocator, "https://example.com"));
}

test "approved origin store rejects an existing permissive store" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var existing = try tmp.dir.createFile(store_file_name, .{ .mode = 0o644 });
    try existing.writeAll("{\n  \"version\": 1,\n  \"origins\": []\n}\n");
    try existing.chmod(0o644);
    existing.close();
    try std.testing.expectError(error.UnreadableStore, approveInDir(tmp.dir, allocator, "https://example.com"));
}

test "approved origin store rejects symlink store and lock files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var store_link = std.testing.tmpDir(.{});
    defer store_link.cleanup();
    var target = try store_link.dir.createFile("target", .{ .mode = 0o600 });
    try target.writeAll("{\n  \"version\": 1,\n  \"origins\": []\n}\n");
    target.close();
    try store_link.dir.symLink("target", store_file_name, .{});
    try std.testing.expectError(error.UnreadableStore, isApprovedInDir(store_link.dir, allocator, "https://example.com"));

    var lock_link = std.testing.tmpDir(.{});
    defer lock_link.cleanup();
    var lock_target = try lock_link.dir.createFile("target", .{ .mode = 0o600 });
    lock_target.close();
    try lock_link.dir.symLink("target", lock_file_name, .{});
    try std.testing.expectError(error.UnreadableStore, approveInDir(lock_link.dir, allocator, "https://example.com"));
}

test "approved origin store enforces the persisted size cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store: Store = .{};
    defer store.deinit(allocator);
    var index: usize = 0;
    while (index < max_origins) : (index += 1) {
        const origin = try std.fmt.allocPrint(allocator, "https://{s}{d}.example:443", .{ "a" ** 250, index });
        try store.origins.append(allocator, origin);
    }
    try std.testing.expectError(error.StoreTooLarge, persistStore(tmp.dir, allocator, &store));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(store_file_name, .{}));
}

test "approved origin store writes mode 0600 atomically" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expect(try approveInDir(tmp.dir, allocator, "https://example.com"));
    const stat = try tmp.dir.statFile(store_file_name);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);

    var iterator = tmp.dir.iterate();
    while (try iterator.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".approved-origins.json.tmp-"));
    }
}

fn failDirectorySync(_: std.fs.Dir) anyerror!void {
    return error.InjectedSyncFailure;
}

test "atomic store reports committed durability uncertainty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const body = "{\n  \"version\": 1,\n  \"origins\": []\n}\n";
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try std.testing.expectError(
        error.StoreCommittedDurabilityUncertain,
        writePrivateFileAtomicWithSync(tmp.dir, allocator, store_file_name, body, failDirectorySync),
    );
    const committed = try tmp.dir.readFileAlloc(allocator, store_file_name, max_store_bytes);
    defer allocator.free(committed);
    try std.testing.expectEqualStrings(body, committed);

    try writePrivateFileAtomic(tmp.dir, allocator, store_file_name, body);
    var iterator = tmp.dir.iterate();
    while (try iterator.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".approved-origins.json.tmp-"));
    }
}

const TestEnv = if (builtin.os.tag == .windows) struct {} else struct {
    allocator: std.mem.Allocator,
    name: []u8,
    original: ?[]u8,

    fn capture(allocator: std.mem.Allocator, name: []const u8) !@This() {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .original = if (std.posix.getenv(name)) |value| try allocator.dupe(u8, value) else null,
        };
    }

    fn restore(self: *@This()) void {
        if (self.original) |value| {
            setEnv(self.name, value) catch {};
            self.allocator.free(value);
        } else {
            unsetEnv(self.name);
        }
        self.allocator.free(self.name);
        self.* = undefined;
    }
};

fn setEnv(name: []const u8, value: []const u8) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    const c_fns = struct {
        extern fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    };
    const name_z = try std.testing.allocator.dupeZ(u8, name);
    defer std.testing.allocator.free(name_z);
    const value_z = try std.testing.allocator.dupeZ(u8, value);
    defer std.testing.allocator.free(value_z);
    if (c_fns.setenv(name_z, value_z, 1) != 0) return error.SetEnvFailed;
}

fn unsetEnv(name: []const u8) void {
    if (builtin.os.tag == .windows) return;
    const c_fns = struct {
        extern fn unsetenv([*:0]const u8) c_int;
    };
    const name_z = std.testing.allocator.dupeZ(u8, name) catch return;
    defer std.testing.allocator.free(name_z);
    _ = c_fns.unsetenv(name_z);
}

test "global approval APIs fail closed on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedPlatform, isApproved(allocator, "https://example.com"));
    try std.testing.expectError(error.UnsupportedPlatform, approve(allocator, "https://example.com"));
}

test "global approval validates input before missing filesystem state" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var env = try TestEnv.capture(allocator, "HOME");
    defer env.restore();
    try setEnv("HOME", home);

    try std.testing.expectError(error.HttpsRequired, isApproved(allocator, "http://example.com"));
    try std.testing.expectError(error.QueryNotAllowed, isApproved(allocator, "https://example.com?credential=secret"));
    try std.testing.expectError(error.UserinfoNotAllowed, isApproved(allocator, "https://user@example.com"));
}

test "global approved origin store rejects a config directory symlink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var env = try TestEnv.capture(allocator, "HOME");
    defer env.restore();
    try setEnv("HOME", home);

    try tmp.dir.makePath(".config/outside");
    try tmp.dir.symLink("outside", ".config/cog", .{ .is_directory = true });
    try std.testing.expectError(error.UnreadableStore, approve(allocator, "https://example.com"));
    try std.testing.expectError(error.UnreadableStore, isApproved(allocator, "https://example.com"));
}

test "approved origin operations retain the validated directory handle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("config");
    var initial = try tmp.dir.openDir("config", .{});
    try initial.chmod(0o700);
    initial.close();
    const config_path = try tmp.dir.realpathAlloc(allocator, "config");
    defer allocator.free(config_path);

    var validated = try openValidatedConfigDir(config_path, false);
    defer validated.close();
    try tmp.dir.rename("config", "validated");
    try tmp.dir.makeDir("config");

    try std.testing.expect(try approveCanonicalOriginInDir(validated, allocator, "https://example.com:443"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("config/approved-origins.json", .{}));
    try tmp.dir.access("validated/approved-origins.json", .{});
}

test "global approved origin store ignores repository-local configuration" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);
    var env = try TestEnv.capture(allocator, "HOME");
    defer env.restore();
    try setEnv("HOME", home);

    try tmp.dir.makePath("project/.cog");
    try tmp.dir.writeFile(.{
        .sub_path = "project/.cog/approved-origins.json",
        .data =
        \\{
        \\  "version": 1,
        \\  "origins": ["https://repo.example:443"]
        \\}
        \\
        ,
    });

    try std.testing.expect(!try isApproved(allocator, "https://repo.example"));
    try std.testing.expect(try approve(allocator, "https://global.example"));
    try std.testing.expect(try isApproved(allocator, "https://global.example:443"));
    try std.testing.expect(!try isApproved(allocator, "https://repo.example"));

    const stat = try tmp.dir.statFile(".config/cog/approved-origins.json");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
    var config_dir = try tmp.dir.openDir(".config/cog", .{});
    defer config_dir.close();
    const dir_stat = try std.posix.fstat(config_dir.fd);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), dir_stat.mode & 0o777);
}
