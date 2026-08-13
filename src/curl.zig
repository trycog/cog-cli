const std = @import("std");
const c = @import("curl").libcurl;
const debug_log = @import("debug_log.zig");

var download_temp_counter = std.atomic.Value(u64).init(0);

const DownloadStage = struct {
    parent: *std.fs.Dir,
    allocator: std.mem.Allocator,
    name: []u8,
    output_name: []const u8,
    file: std.fs.File,
    file_open: bool = true,
    promoted: bool = false,

    fn init(
        parent: *std.fs.Dir,
        allocator: std.mem.Allocator,
        output_name: []const u8,
    ) !DownloadStage {
        const sequence = download_temp_counter.fetchAdd(1, .monotonic);
        const name = try std.fmt.allocPrint(
            allocator,
            ".{s}.download-{d}-{d}.tmp",
            .{ output_name, std.time.nanoTimestamp(), sequence },
        );
        errdefer allocator.free(name);

        debug_log.log("downloadToFile: creating staged file {s}", .{name});
        const file = try parent.createFile(name, .{ .exclusive = true, .mode = 0o600 });
        return .{
            .parent = parent,
            .allocator = allocator,
            .name = name,
            .output_name = output_name,
            .file = file,
        };
    }

    fn promote(self: *DownloadStage) !void {
        debug_log.log("downloadToFile: syncing staged file {s}", .{self.name});
        try self.file.sync();
        self.file.close();
        self.file_open = false;

        debug_log.log("downloadToFile: promoting {s} to {s}", .{ self.name, self.output_name });
        try self.parent.rename(self.name, self.output_name);
        self.promoted = true;
    }

    fn deinit(self: *DownloadStage) void {
        if (self.file_open) self.file.close();
        if (!self.promoted) {
            self.parent.deleteFile(self.name) catch |err| {
                debug_log.log("downloadToFile: failed to clean staged file {s}: {s}", .{ self.name, @errorName(err) });
            };
        }
        self.allocator.free(self.name);
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
};

pub fn globalInit() void {
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
}

pub fn globalCleanup() void {
    c.curl_global_cleanup();
}

pub const PostResult = struct {
    status_code: u16,
    body: []const u8,
    headers: []const u8,
};

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !HttpResponse {
    return fetch(allocator, url, .POST, headers, body);
}

pub fn postCapturingHeaders(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !PostResult {
    return fetchCapturingHeaders(allocator, url, headers, body);
}

pub fn get(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    return fetch(allocator, url, .GET, headers, null);
}

/// Result metadata for a successful streaming download.
pub const DownloadResult = struct {
    status_code: u16,
    bytes_written: usize,
};

/// Stream a GET response into a mode-0600 sibling staging file, then atomically
/// replace `output_path` only after curl succeeds and the final status is 2xx.
/// The staged file is deleted on transport, status, write, or size-limit errors.
pub fn downloadToFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    output_path: []const u8,
    max_bytes: usize,
) !DownloadResult {
    globalInit();

    const parent_path = std.fs.path.dirname(output_path) orelse return error.InvalidOutputPath;
    const output_name = std.fs.path.basename(output_path);
    if (output_name.len == 0 or std.mem.eql(u8, output_name, ".") or std.mem.eql(u8, output_name, "..")) {
        return error.InvalidOutputPath;
    }

    var parent = try std.fs.openDirAbsolute(parent_path, .{});
    defer parent.close();

    var stage = try DownloadStage.init(&parent, allocator, output_name);
    defer stage.deinit();
    debug_log.log("downloadToFile: staging {s} as {s} with cap {d}", .{ output_path, stage.name, max_bytes });

    const handle = c.curl_easy_init() orelse return error.HttpError;
    defer c.curl_easy_cleanup(handle);

    var ca_bundle_z: ?[:0]u8 = null;
    defer if (ca_bundle_z) |p| allocator.free(p);

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url_z.ptr);

    if (findCaBundlePath(allocator)) |ca_path| {
        ca_bundle_z = ca_path;
        _ = c.curl_easy_setopt(handle, c.CURLOPT_CAINFO, ca_path.ptr);
    }

    var header_list: ?*c.struct_curl_slist = null;
    for (headers) |h| {
        const h_z = try allocator.dupeZ(u8, h);
        defer allocator.free(h_z);
        const appended = c.curl_slist_append(header_list, h_z.ptr) orelse return error.OutOfMemory;
        header_list = appended;
    }
    defer if (header_list) |hl| c.curl_slist_free_all(hl);
    if (header_list) |hl| {
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTPHEADER, hl);
    }

    _ = c.curl_easy_setopt(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 30));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 120));

    var callback_data = FileWriteCallbackData{
        .file = &stage.file,
        .max_bytes = max_bytes,
    };
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, &fileWriteCallback);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&callback_data)));

    debug_log.log("downloadToFile: GET {s}", .{url});
    const res = c.curl_easy_perform(handle);
    if (callback_data.failure == .response_too_large) {
        debug_log.log("downloadToFile: response exceeded cap for {s} after {d} bytes", .{ url, callback_data.bytes_written });
        return error.ResponseTooLarge;
    }
    if (callback_data.failure == .file_write) {
        const write_error = callback_data.write_error orelse error.Unexpected;
        debug_log.log("downloadToFile: write failed for {s}: {s}", .{ output_path, @errorName(write_error) });
        return write_error;
    }
    if (res != c.CURLE_OK) {
        debug_log.log("downloadToFile: curl error for {s}", .{url});
        return error.HttpError;
    }

    var status_code: c_long = 0;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code) != c.CURLE_OK) {
        debug_log.log("downloadToFile: failed to read status for {s}", .{url});
        return error.HttpError;
    }
    const validated_status = validateDownloadStatus(status_code) catch |err| {
        debug_log.log("downloadToFile: rejected status {d} for {s}", .{ status_code, url });
        return err;
    };

    try stage.promote();
    debug_log.log("downloadToFile: completed {s} status {d} bytes {d}", .{ output_path, validated_status, callback_data.bytes_written });

    return .{
        .status_code = validated_status,
        .bytes_written = callback_data.bytes_written,
    };
}

fn validateDownloadStatus(status_code: c_long) !u16 {
    if (status_code < 200 or status_code >= 300) return error.HttpStatusError;
    return @intCast(status_code);
}

const Method = enum { GET, POST };

fn fetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    method: Method,
    headers: []const []const u8,
    body: ?[]const u8,
) !HttpResponse {
    // Ensure libcurl global state is initialized even when callers (like
    // MCP mode) intentionally skip eager startup init for faster boot.
    globalInit();

    const handle = c.curl_easy_init() orelse return error.HttpError;
    defer c.curl_easy_cleanup(handle);

    var ca_bundle_z: ?[:0]u8 = null;
    defer if (ca_bundle_z) |p| allocator.free(p);

    // URL (needs null terminator)
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url_z.ptr);

    // Ensure TLS trust roots are available for vendored libcurl+mbedTLS builds.
    // On some platforms this is not auto-discovered, which causes HTTPS calls
    // to fail even when system curl succeeds.
    if (findCaBundlePath(allocator)) |ca_path| {
        ca_bundle_z = ca_path;
        _ = c.curl_easy_setopt(handle, c.CURLOPT_CAINFO, ca_path.ptr);
    }

    // Method
    if (method == .POST) {
        _ = c.curl_easy_setopt(handle, c.CURLOPT_POST, @as(c_long, 1));
    }

    // Request body
    if (body) |b| {
        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, b.ptr);
    } else if (method == .POST) {
        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, @as(?[*]const u8, null));
    }

    // Headers
    var header_list: ?*c.struct_curl_slist = null;
    for (headers) |h| {
        const h_z = try allocator.dupeZ(u8, h);
        defer allocator.free(h_z);
        header_list = c.curl_slist_append(header_list, h_z.ptr);
    }
    defer if (header_list) |hl| c.curl_slist_free_all(hl);
    if (header_list) |hl| {
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTPHEADER, hl);
    }

    // Accept compressed responses (curl handles decompression automatically)
    _ = c.curl_easy_setopt(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""));

    // Follow redirects
    _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    // Timeouts — prevent indefinite hangs on unresponsive servers
    _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 30));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 120));

    // Response body via write callback
    var response_data = WriteCallbackData{
        .list = .empty,
        .allocator = allocator,
        .err = false,
    };
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&response_data)));

    // Perform
    debug_log.log("fetch: {s} {s}", .{ @tagName(method), url });
    const res = c.curl_easy_perform(handle);
    if (res != c.CURLE_OK) {
        debug_log.log("fetch: curl error for {s}", .{url});
        response_data.list.deinit(allocator);
        return error.HttpError;
    }
    if (response_data.err) {
        response_data.list.deinit(allocator);
        return error.OutOfMemory;
    }

    // Get status code
    var status_code: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code);
    debug_log.log("fetch: {s} {s} -> status {d}", .{ @tagName(method), url, status_code });

    return .{
        .status_code = @intCast(status_code),
        .body = try response_data.list.toOwnedSlice(allocator),
    };
}

fn fetchCapturingHeaders(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !PostResult {
    globalInit();

    const handle = c.curl_easy_init() orelse return error.HttpError;
    defer c.curl_easy_cleanup(handle);

    var ca_bundle_z: ?[:0]u8 = null;
    defer if (ca_bundle_z) |p| allocator.free(p);

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url_z.ptr);

    if (findCaBundlePath(allocator)) |ca_path| {
        ca_bundle_z = ca_path;
        _ = c.curl_easy_setopt(handle, c.CURLOPT_CAINFO, ca_path.ptr);
    }

    _ = c.curl_easy_setopt(handle, c.CURLOPT_POST, @as(c_long, 1));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, body.ptr);

    var header_list: ?*c.struct_curl_slist = null;
    for (headers) |h| {
        const h_z = try allocator.dupeZ(u8, h);
        defer allocator.free(h_z);
        header_list = c.curl_slist_append(header_list, h_z.ptr);
    }
    defer if (header_list) |hl| c.curl_slist_free_all(hl);
    if (header_list) |hl| {
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTPHEADER, hl);
    }

    _ = c.curl_easy_setopt(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    // Timeouts — prevent indefinite hangs on unresponsive servers
    _ = c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 30));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 120));

    // Response body
    var response_data = WriteCallbackData{
        .list = .empty,
        .allocator = allocator,
        .err = false,
    };
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&response_data)));

    // Response headers
    var header_data = WriteCallbackData{
        .list = .empty,
        .allocator = allocator,
        .err = false,
    };
    _ = c.curl_easy_setopt(handle, c.CURLOPT_HEADERFUNCTION, &writeCallback);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&header_data)));

    debug_log.log("fetchCapturingHeaders: POST {s} (body {d} bytes)", .{ url, body.len });
    const res = c.curl_easy_perform(handle);
    if (res != c.CURLE_OK) {
        debug_log.log("fetchCapturingHeaders: curl error for {s}", .{url});
        response_data.list.deinit(allocator);
        header_data.list.deinit(allocator);
        return error.HttpError;
    }
    if (response_data.err or header_data.err) {
        response_data.list.deinit(allocator);
        header_data.list.deinit(allocator);
        return error.OutOfMemory;
    }

    var status_code: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code);
    debug_log.log("fetchCapturingHeaders: {s} -> status {d}, headers {d} bytes", .{ url, status_code, header_data.list.items.len });

    return .{
        .status_code = @intCast(status_code),
        .body = try response_data.list.toOwnedSlice(allocator),
        .headers = try header_data.list.toOwnedSlice(allocator),
    };
}

fn findCaBundlePath(allocator: std.mem.Allocator) ?[:0]u8 {
    const env_candidates = [_][]const u8{ "CURL_CA_BUNDLE", "SSL_CERT_FILE" };
    for (env_candidates) |name| {
        if (std.posix.getenv(name)) |value| {
            const path: []const u8 = value;
            if (path.len != 0 and fileExists(path)) {
                debug_log.log("CA bundle: env {s} = {s}", .{ name, path });
                return allocator.dupeZ(u8, path) catch null;
            }
        }
    }

    const defaults = [_][]const u8{
        "/etc/ssl/cert.pem", // macOS
        "/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu
        "/etc/pki/tls/certs/ca-bundle.crt", // RHEL/CentOS/Fedora
        "/opt/homebrew/etc/openssl@3/cert.pem", // Homebrew (Apple Silicon)
        "/usr/local/etc/openssl@3/cert.pem", // Homebrew (Intel)
    };

    for (defaults) |path| {
        if (fileExists(path)) {
            debug_log.log("CA bundle: using {s}", .{path});
            return allocator.dupeZ(u8, path) catch null;
        }
    }

    debug_log.log("CA bundle: none found", .{});
    return null;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

const WriteCallbackData = struct {
    list: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    err: bool,
};

const FileWriteFailure = enum {
    none,
    response_too_large,
    file_write,
};

const FileWriteCallbackData = struct {
    file: *std.fs.File,
    max_bytes: usize,
    bytes_written: usize = 0,
    failure: FileWriteFailure = .none,
    write_error: ?anyerror = null,
};

fn fileWriteCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const data: *FileWriteCallbackData = @ptrCast(@alignCast(userdata));
    if (data.failure != .none) return 0;

    const total = std.math.mul(usize, size, nmemb) catch {
        data.failure = .response_too_large;
        return 0;
    };
    if (total > data.max_bytes -| data.bytes_written) {
        data.failure = .response_too_large;
        return 0;
    }

    data.file.writeAll(ptr[0..total]) catch |err| {
        data.failure = .file_write;
        data.write_error = err;
        return 0;
    };
    data.bytes_written += total;
    return total;
}

fn writeCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const data: *WriteCallbackData = @ptrCast(@alignCast(userdata));
    const total = size * nmemb;
    data.list.appendSlice(data.allocator, ptr[0..total]) catch {
        data.err = true;
        return 0;
    };
    return total;
}

test "fileWriteCallback streams chunks up to the size cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("archive.tmp", .{ .read = true, .mode = 0o600 });
    defer file.close();
    var data = FileWriteCallbackData{
        .file = &file,
        .max_bytes = 6,
    };

    const first = "abc";
    const second = "def";
    try std.testing.expectEqual(first.len, fileWriteCallback(first.ptr, 1, first.len, @ptrCast(&data)));
    try std.testing.expectEqual(second.len, fileWriteCallback(second.ptr, 1, second.len, @ptrCast(&data)));
    try std.testing.expectEqual(@as(usize, 6), data.bytes_written);
    try std.testing.expectEqual(FileWriteFailure.none, data.failure);

    try file.seekTo(0);
    var contents: [6]u8 = undefined;
    try std.testing.expectEqual(contents.len, try file.readAll(&contents));
    try std.testing.expectEqualStrings("abcdef", &contents);
}

test "fileWriteCallback rejects a chunk that exceeds the size cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("archive.tmp", .{ .read = true, .mode = 0o600 });
    defer file.close();
    var data = FileWriteCallbackData{
        .file = &file,
        .max_bytes = 5,
    };

    const first = "abc";
    const second = "def";
    try std.testing.expectEqual(first.len, fileWriteCallback(first.ptr, 1, first.len, @ptrCast(&data)));
    try std.testing.expectEqual(@as(usize, 0), fileWriteCallback(second.ptr, 1, second.len, @ptrCast(&data)));
    try std.testing.expectEqual(@as(usize, 3), data.bytes_written);
    try std.testing.expectEqual(FileWriteFailure.response_too_large, data.failure);

    try file.seekTo(0);
    var contents: [3]u8 = undefined;
    try std.testing.expectEqual(contents.len, try file.readAll(&contents));
    try std.testing.expectEqualStrings("abc", &contents);
}

test "fileWriteCallback rejects an overflowing callback length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("archive.tmp", .{ .mode = 0o600 });
    defer file.close();
    var data = FileWriteCallbackData{
        .file = &file,
        .max_bytes = std.math.maxInt(usize),
    };

    const byte = [_]u8{0};
    try std.testing.expectEqual(
        @as(usize, 0),
        fileWriteCallback(byte[0..].ptr, std.math.maxInt(usize), 2, @ptrCast(&data)),
    );
    try std.testing.expectEqual(FileWriteFailure.response_too_large, data.failure);
    try std.testing.expectEqual(@as(usize, 0), data.bytes_written);
}

test "fileWriteCallback records file write errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("archive.tmp", .{ .mode = 0o600 });
    file.close();
    var data = FileWriteCallbackData{
        .file = &file,
        .max_bytes = 16,
    };

    const bytes = "data";
    try std.testing.expectEqual(@as(usize, 0), fileWriteCallback(bytes.ptr, 1, bytes.len, @ptrCast(&data)));
    try std.testing.expectEqual(FileWriteFailure.file_write, data.failure);
    try std.testing.expect(data.write_error != null);
}

test "DownloadStage creates a mode 0600 sibling and removes it when abandoned" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "archive.tar.gz", .data = "old archive" });
    var stage = try DownloadStage.init(&tmp.dir, allocator, "archive.tar.gz");
    const staged_name = try allocator.dupe(u8, stage.name);
    defer allocator.free(staged_name);

    const stat = try stage.file.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
    stage.deinit();

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(staged_name, .{}));
    const destination = try tmp.dir.readFileAlloc(allocator, "archive.tar.gz", 1024);
    defer allocator.free(destination);
    try std.testing.expectEqualStrings("old archive", destination);
}

test "DownloadStage promotes complete contents over the destination" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "archive.tar.gz", .data = "old" });
    var stage = try DownloadStage.init(&tmp.dir, allocator, "archive.tar.gz");
    defer stage.deinit();
    try stage.file.writeAll("new archive");
    try stage.promote();

    const contents = try tmp.dir.readFileAlloc(allocator, "archive.tar.gz", 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("new archive", contents);
}

test "DownloadStage removes staged contents when promotion fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("archive.tar.gz");
    var staged_name: []u8 = undefined;
    {
        var stage = try DownloadStage.init(&tmp.dir, allocator, "archive.tar.gz");
        defer stage.deinit();
        staged_name = try allocator.dupe(u8, stage.name);
        try stage.file.writeAll("new archive");
        const promotion_succeeded = if (stage.promote()) |_| true else |_| false;
        try std.testing.expect(!promotion_succeeded);
    }
    defer allocator.free(staged_name);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(staged_name, .{}));
    var destination = try tmp.dir.openDir("archive.tar.gz", .{});
    destination.close();
}

test "validateDownloadStatus accepts only 2xx responses" {
    try std.testing.expectError(error.HttpStatusError, validateDownloadStatus(199));
    try std.testing.expectEqual(@as(u16, 200), try validateDownloadStatus(200));
    try std.testing.expectEqual(@as(u16, 299), try validateDownloadStatus(299));
    try std.testing.expectError(error.HttpStatusError, validateDownloadStatus(300));
}
