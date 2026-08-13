const std = @import("std");
const c = @import("curl").libcurl;
const debug_log = @import("debug_log.zig");

const DEFAULT_MAX_RESPONSE_BYTES: usize = 256 * 1024 * 1024;
const MAX_RESPONSE_SIZE_LIMIT: usize = 1024 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 1024 * 1024;
const MAX_REDIRECTS: c_long = 5;
const CONNECT_TIMEOUT_MS: c_long = 30_000;
const TOTAL_TIMEOUT_MS: c_long = 120_000;

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

        debug_log.log("downloadToFile: creating sibling staged file", .{});
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
        debug_log.log("downloadToFile: syncing staged file", .{});
        try self.file.sync();
        self.file.close();
        self.file_open = false;

        debug_log.log("downloadToFile: promoting staged file", .{});
        try self.parent.rename(self.name, self.output_name);
        self.promoted = true;
    }

    fn deinit(self: *DownloadStage) void {
        if (self.file_open) self.file.close();
        if (!self.promoted) {
            self.parent.deleteFile(self.name) catch |err| {
                debug_log.log("downloadToFile: staged file cleanup failure: {s}", .{@errorName(err)});
            };
        }
        self.allocator.free(self.name);
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
};

var global_init_once = std.once(initCurlGlobal);

fn initCurlGlobal() void {
    const result = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    if (result != c.CURLE_OK) {
        debug_log.log("curl global init failure: code={d}", .{result});
    }
}

pub fn globalInit() void {
    global_init_once.call();
}

/// Curl global state intentionally remains initialized for process lifetime.
/// Per libcurl guidance, cleanup is optional at process exit; making this a
/// no-op avoids racing active requests or unbalancing once-only initialization.
pub fn globalCleanup() void {}

pub const PostResult = struct {
    status_code: u16,
    body: []const u8,
    headers: []const u8,
};

/// Per-request response allocation bounds. The body limit applies after curl
/// decompresses content, so compressed responses cannot bypass it.
pub const RequestOptions = struct {
    max_response_bytes: usize = DEFAULT_MAX_RESPONSE_BYTES,

    fn validate(self: RequestOptions) !void {
        if (self.max_response_bytes == 0 or self.max_response_bytes > MAX_RESPONSE_SIZE_LIMIT) {
            return error.InvalidResponseSizeLimit;
        }
    }
};

const RequestMode = enum {
    authenticated,
    public_unauthenticated,
};

const TransportPolicy = struct {
    mode: RequestMode,
    initial_protocols: [*:0]const u8,
    redirect_protocols: [*:0]const u8,
    follow_redirects: c_long,
    max_redirects: c_long,
    no_signal: c_long = 1,
    verify_peer: c_long = 1,
    verify_host: c_long = 2,
    connect_timeout_ms: c_long = CONNECT_TIMEOUT_MS,
    total_timeout_ms: c_long = TOTAL_TIMEOUT_MS,
};

fn transportPolicy(headers: []const []const u8) TransportPolicy {
    if (hasAuthorizationHeader(headers)) {
        return .{
            .mode = .authenticated,
            .initial_protocols = "https",
            .redirect_protocols = "https",
            .follow_redirects = 0,
            .max_redirects = 0,
        };
    }

    return .{
        .mode = .public_unauthenticated,
        .initial_protocols = "https",
        .redirect_protocols = "https",
        .follow_redirects = 1,
        .max_redirects = MAX_REDIRECTS,
    };
}

fn hasAuthorizationHeader(headers: []const []const u8) bool {
    for (headers) |header| {
        const trimmed = std.mem.trimLeft(u8, header, " \t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trimRight(u8, trimmed[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Authorization")) return true;
    }
    return false;
}

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !HttpResponse {
    return postWithOptions(allocator, url, headers, body, .{});
}

/// Send a POST request with an explicit response-size allocation cap.
pub fn postWithOptions(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    options: RequestOptions,
) !HttpResponse {
    try options.validate();
    return fetch(allocator, url, .POST, headers, body, options);
}

pub fn postCapturingHeaders(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !PostResult {
    return postCapturingHeadersWithOptions(allocator, url, headers, body, .{});
}

/// Send a POST request while capturing headers with an explicit body-size cap.
pub fn postCapturingHeadersWithOptions(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    options: RequestOptions,
) !PostResult {
    try options.validate();
    return fetchCapturingHeaders(allocator, url, headers, body, options);
}

pub fn get(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    return getWithOptions(allocator, url, headers, .{});
}

/// Send a GET request with an explicit response-size allocation cap.
pub fn getWithOptions(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    options: RequestOptions,
) !HttpResponse {
    try options.validate();
    return fetch(allocator, url, .GET, headers, null, options);
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
    try (RequestOptions{ .max_response_bytes = max_bytes }).validate();

    const parent_path = std.fs.path.dirname(output_path) orelse return error.InvalidOutputPath;
    const output_name = std.fs.path.basename(output_path);
    if (output_name.len == 0 or std.mem.eql(u8, output_name, ".") or std.mem.eql(u8, output_name, "..")) {
        return error.InvalidOutputPath;
    }

    var parent = try std.fs.openDirAbsolute(parent_path, .{});
    defer parent.close();

    var stage = try DownloadStage.init(&parent, allocator, output_name);
    defer stage.deinit();
    debug_log.log("downloadToFile: staged destination with cap={d}", .{max_bytes});

    const handle = c.curl_easy_init() orelse {
        debug_log.log("downloadToFile: curl handle initialization failure", .{});
        return error.HttpError;
    };
    defer c.curl_easy_cleanup(handle);

    var ca_bundle_z: ?[:0]u8 = null;
    defer if (ca_bundle_z) |p| allocator.free(p);

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    try setopt(handle, c.CURLOPT_URL, url_z.ptr, "URL");

    if (findCaBundlePath(allocator)) |ca_path| {
        ca_bundle_z = ca_path;
        try setopt(handle, c.CURLOPT_CAINFO, ca_path.ptr, "CAINFO");
    }

    var header_list: ?*c.struct_curl_slist = null;
    for (headers) |h| {
        const h_z = try allocator.dupeZ(u8, h);
        defer allocator.free(h_z);
        const appended = c.curl_slist_append(header_list, h_z.ptr) orelse {
            debug_log.log("curl header setup failure: out of memory", .{});
            return error.OutOfMemory;
        };
        header_list = appended;
    }
    defer if (header_list) |hl| c.curl_slist_free_all(hl);
    if (header_list) |hl| {
        try setopt(handle, c.CURLOPT_HTTPHEADER, hl, "HTTPHEADER");
    }

    try setopt(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""), "ACCEPT_ENCODING");
    try applyTransportPolicy(handle, transportPolicy(headers), max_bytes);

    var callback_data = FileWriteCallbackData{
        .file = &stage.file,
        .max_bytes = max_bytes,
    };
    try setopt(handle, c.CURLOPT_WRITEFUNCTION, &fileWriteCallback, "WRITEFUNCTION");
    try setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&callback_data)), "WRITEDATA");

    debug_log.log("downloadToFile: starting GET with cap={d}", .{max_bytes});
    const res = c.curl_easy_perform(handle);
    if (callback_data.failure == .response_too_large) {
        debug_log.log("downloadToFile: response limit exceeded after bytes={d} cap={d}", .{ callback_data.bytes_written, max_bytes });
        return error.ResponseTooLarge;
    }
    if (callback_data.failure == .file_write) {
        const write_error = callback_data.write_error orelse error.Unexpected;
        debug_log.log("downloadToFile: staged file write failure: {s}", .{@errorName(write_error)});
        return write_error;
    }
    if (res != c.CURLE_OK) {
        debug_log.log("downloadToFile: curl failure code={d}", .{res});
        return error.HttpError;
    }

    var status_code: c_long = 0;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code) != c.CURLE_OK) {
        debug_log.log("downloadToFile: curl getinfo failure", .{});
        return error.HttpError;
    }
    const validated_status = validateDownloadStatus(status_code) catch |err| {
        debug_log.log("downloadToFile: rejected status={d}", .{status_code});
        return err;
    };

    try stage.promote();
    debug_log.log("downloadToFile: completed status={d} bytes={d}", .{ validated_status, callback_data.bytes_written });

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
    options: RequestOptions,
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
    try setopt(handle, c.CURLOPT_URL, url_z.ptr, "URL");

    // Ensure TLS trust roots are available for vendored libcurl+mbedTLS builds.
    // On some platforms this is not auto-discovered, which causes HTTPS calls
    // to fail even when system curl succeeds.
    if (findCaBundlePath(allocator)) |ca_path| {
        ca_bundle_z = ca_path;
        try setopt(handle, c.CURLOPT_CAINFO, ca_path.ptr, "CAINFO");
    }

    // Method
    if (method == .POST) {
        try setopt(handle, c.CURLOPT_POST, @as(c_long, 1), "POST");
    }

    // Request body
    if (body) |b| {
        try setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len)), "POSTFIELDSIZE");
        try setopt(handle, c.CURLOPT_POSTFIELDS, b.ptr, "POSTFIELDS");
    } else if (method == .POST) {
        try setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0), "POSTFIELDSIZE");
        try setopt(handle, c.CURLOPT_POSTFIELDS, @as(?[*]const u8, null), "POSTFIELDS");
    }

    // Headers
    var header_list: ?*c.struct_curl_slist = null;
    for (headers) |h| {
        const h_z = try allocator.dupeZ(u8, h);
        defer allocator.free(h_z);
        const appended = c.curl_slist_append(header_list, h_z.ptr) orelse {
            debug_log.log("curl header setup failure: out of memory", .{});
            return error.OutOfMemory;
        };
        header_list = appended;
    }
    defer if (header_list) |hl| c.curl_slist_free_all(hl);
    if (header_list) |hl| {
        try setopt(handle, c.CURLOPT_HTTPHEADER, hl, "HTTPHEADER");
    }

    // Accept compressed responses (curl handles decompression automatically)
    try setopt(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""), "ACCEPT_ENCODING");

    try applyTransportPolicy(handle, transportPolicy(headers), options.max_response_bytes);

    // Response body via write callback
    var response_data = WriteCallbackData.init(allocator, .body, options.max_response_bytes);
    try setopt(handle, c.CURLOPT_WRITEFUNCTION, &writeCallback, "WRITEFUNCTION");
    try setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&response_data)), "WRITEDATA");

    // Perform
    debug_log.log("fetch: starting method={s}", .{@tagName(method)});
    const res = c.curl_easy_perform(handle);
    if (res != c.CURLE_OK) {
        debug_log.log("fetch: curl failure code={d}", .{res});
        response_data.list.deinit(allocator);
        return callbackFailure(response_data.failure) orelse error.HttpError;
    }
    if (callbackFailure(response_data.failure)) |failure| {
        response_data.list.deinit(allocator);
        return failure;
    }

    // Get status code
    var status_code: c_long = 0;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code) != c.CURLE_OK) {
        response_data.list.deinit(allocator);
        debug_log.log("fetch: curl getinfo failure", .{});
        return error.HttpError;
    }
    debug_log.log("fetch: completed method={s} status={d} bytes={d}", .{ @tagName(method), status_code, response_data.list.items.len });

    return takeHttpResponse(allocator, status_code, &response_data);
}

fn takeHttpResponse(
    allocator: std.mem.Allocator,
    status_code: c_long,
    response_data: *WriteCallbackData,
) !HttpResponse {
    errdefer response_data.list.deinit(allocator);
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
    options: RequestOptions,
) !PostResult {
    globalInit();

    const handle = c.curl_easy_init() orelse return error.HttpError;
    defer c.curl_easy_cleanup(handle);

    var ca_bundle_z: ?[:0]u8 = null;
    defer if (ca_bundle_z) |p| allocator.free(p);

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    try setopt(handle, c.CURLOPT_URL, url_z.ptr, "URL");

    if (findCaBundlePath(allocator)) |ca_path| {
        ca_bundle_z = ca_path;
        try setopt(handle, c.CURLOPT_CAINFO, ca_path.ptr, "CAINFO");
    }

    try setopt(handle, c.CURLOPT_POST, @as(c_long, 1), "POST");
    try setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)), "POSTFIELDSIZE");
    try setopt(handle, c.CURLOPT_POSTFIELDS, body.ptr, "POSTFIELDS");

    var header_list: ?*c.struct_curl_slist = null;
    for (headers) |h| {
        const h_z = try allocator.dupeZ(u8, h);
        defer allocator.free(h_z);
        const appended = c.curl_slist_append(header_list, h_z.ptr) orelse {
            debug_log.log("curl header setup failure: out of memory", .{});
            return error.OutOfMemory;
        };
        header_list = appended;
    }
    defer if (header_list) |hl| c.curl_slist_free_all(hl);
    if (header_list) |hl| {
        try setopt(handle, c.CURLOPT_HTTPHEADER, hl, "HTTPHEADER");
    }

    try setopt(handle, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""), "ACCEPT_ENCODING");
    try applyTransportPolicy(handle, transportPolicy(headers), options.max_response_bytes);

    // Response body
    var response_data = WriteCallbackData.init(allocator, .body, options.max_response_bytes);
    try setopt(handle, c.CURLOPT_WRITEFUNCTION, &writeCallback, "WRITEFUNCTION");
    try setopt(handle, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&response_data)), "WRITEDATA");

    // Response headers use their own smaller hard cap and retain only the
    // final response block after redirects or interim responses.
    var header_callback_data = HeaderCallbackData.init(allocator, MAX_HEADER_BYTES);
    const header_data = &header_callback_data.write_data;
    try setopt(handle, c.CURLOPT_HEADERFUNCTION, &headerCallback, "HEADERFUNCTION");
    try setopt(handle, c.CURLOPT_HEADERDATA, @as(*anyopaque, @ptrCast(&header_callback_data)), "HEADERDATA");

    debug_log.log("fetchCapturingHeaders: starting method=POST request_bytes={d}", .{body.len});
    const res = c.curl_easy_perform(handle);
    if (res != c.CURLE_OK) {
        debug_log.log("fetchCapturingHeaders: curl failure code={d}", .{res});
        response_data.list.deinit(allocator);
        header_data.list.deinit(allocator);
        if (callbackFailure(response_data.failure)) |failure| return failure;
        if (callbackFailure(header_data.failure)) |failure| return failure;
        return error.HttpError;
    }
    if (callbackFailure(response_data.failure)) |failure| {
        response_data.list.deinit(allocator);
        header_data.list.deinit(allocator);
        return failure;
    }
    if (callbackFailure(header_data.failure)) |failure| {
        response_data.list.deinit(allocator);
        header_data.list.deinit(allocator);
        return failure;
    }

    var status_code: c_long = 0;
    if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code) != c.CURLE_OK) {
        response_data.list.deinit(allocator);
        header_data.list.deinit(allocator);
        debug_log.log("fetchCapturingHeaders: curl getinfo failure", .{});
        return error.HttpError;
    }
    debug_log.log("fetchCapturingHeaders: completed status={d} body_bytes={d} header_bytes={d}", .{ status_code, response_data.list.items.len, header_data.list.items.len });

    return takePostResult(allocator, status_code, &response_data, header_data);
}

fn takePostResult(
    allocator: std.mem.Allocator,
    status_code: c_long,
    response_data: *WriteCallbackData,
    header_data: *WriteCallbackData,
) !PostResult {
    errdefer response_data.list.deinit(allocator);
    errdefer header_data.list.deinit(allocator);

    const response_body = try response_data.list.toOwnedSlice(allocator);
    errdefer allocator.free(response_body);
    const response_headers = try header_data.list.toOwnedSlice(allocator);

    return .{
        .status_code = @intCast(status_code),
        .body = response_body,
        .headers = response_headers,
    };
}

fn applyTransportPolicy(handle: *c.CURL, policy: TransportPolicy, max_response_bytes: usize) !void {
    debug_log.log(
        "curl setup: mode={s} protocols={s} redirect_protocols={s} follow_redirects={d} max_redirects={d} connect_timeout_ms={d} total_timeout_ms={d} response_cap={d}",
        .{
            @tagName(policy.mode),
            std.mem.span(policy.initial_protocols),
            std.mem.span(policy.redirect_protocols),
            policy.follow_redirects,
            policy.max_redirects,
            policy.connect_timeout_ms,
            policy.total_timeout_ms,
            max_response_bytes,
        },
    );

    try setopt(handle, c.CURLOPT_PROTOCOLS_STR, policy.initial_protocols, "PROTOCOLS_STR");
    try setopt(handle, c.CURLOPT_REDIR_PROTOCOLS_STR, policy.redirect_protocols, "REDIR_PROTOCOLS_STR");
    try setopt(handle, c.CURLOPT_FOLLOWLOCATION, policy.follow_redirects, "FOLLOWLOCATION");
    try setopt(handle, c.CURLOPT_MAXREDIRS, policy.max_redirects, "MAXREDIRS");
    try setopt(handle, c.CURLOPT_NOSIGNAL, policy.no_signal, "NOSIGNAL");
    try setopt(handle, c.CURLOPT_SSL_VERIFYPEER, policy.verify_peer, "SSL_VERIFYPEER");
    try setopt(handle, c.CURLOPT_SSL_VERIFYHOST, policy.verify_host, "SSL_VERIFYHOST");
    try setopt(handle, c.CURLOPT_CONNECTTIMEOUT_MS, policy.connect_timeout_ms, "CONNECTTIMEOUT_MS");
    try setopt(handle, c.CURLOPT_TIMEOUT_MS, policy.total_timeout_ms, "TIMEOUT_MS");
}

fn setopt(handle: *c.CURL, option: c.CURLoption, value: anytype, comptime name: []const u8) !void {
    const result = c.curl_easy_setopt(handle, option, value);
    if (result != c.CURLE_OK) {
        debug_log.log("curl setup failure: option={s} code={d}", .{ name, result });
        return error.HttpError;
    }
}

fn findCaBundlePath(allocator: std.mem.Allocator) ?[:0]u8 {
    const env_candidates = [_][]const u8{ "CURL_CA_BUNDLE", "SSL_CERT_FILE" };
    for (env_candidates) |name| {
        if (std.posix.getenv(name)) |value| {
            const path: []const u8 = value;
            if (path.len != 0 and fileExists(path)) {
                debug_log.log("CA bundle: using environment override {s}", .{name});
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
            debug_log.log("CA bundle: using system default", .{});
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

const ResponsePart = enum {
    body,
    headers,
};

const WriteFailure = enum {
    none,
    out_of_memory,
    response_too_large,
};

const HeaderCallbackData = struct {
    write_data: WriteCallbackData,

    fn init(allocator: std.mem.Allocator, max_bytes: usize) HeaderCallbackData {
        return .{ .write_data = WriteCallbackData.init(allocator, .headers, max_bytes) };
    }
};

const WriteCallbackData = struct {
    list: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    part: ResponsePart,
    max_bytes: usize,
    failure: WriteFailure,

    fn init(allocator: std.mem.Allocator, part: ResponsePart, max_bytes: usize) WriteCallbackData {
        return .{
            .list = .empty,
            .allocator = allocator,
            .part = part,
            .max_bytes = max_bytes,
            .failure = .none,
        };
    }
};

fn headerCallback(
    ptr: [*]const u8,
    size: usize,
    nmemb: usize,
    userdata: *anyopaque,
) callconv(.c) usize {
    const data: *HeaderCallbackData = @ptrCast(@alignCast(userdata));
    const total = std.math.mul(usize, size, nmemb) catch {
        data.write_data.failure = .response_too_large;
        debug_log.log("curl response limit: part=headers chunk_size_overflow cap={d}", .{data.write_data.max_bytes});
        return 0;
    };
    const line = ptr[0..total];
    if (std.mem.startsWith(u8, line, "HTTP/")) {
        data.write_data.list.clearRetainingCapacity();
    }
    return writeCallback(ptr, size, nmemb, @ptrCast(&data.write_data));
}

fn callbackFailure(failure: WriteFailure) ?anyerror {
    return switch (failure) {
        .none => null,
        .out_of_memory => error.OutOfMemory,
        .response_too_large => error.ResponseTooLarge,
    };
}

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
        debug_log.log("curl response limit: part=file chunk_size_overflow cap={d}", .{data.max_bytes});
        return 0;
    };
    if (total > data.max_bytes -| data.bytes_written) {
        data.failure = .response_too_large;
        debug_log.log(
            "curl response limit: part=file current={d} chunk={d} cap={d}",
            .{ data.bytes_written, total, data.max_bytes },
        );
        return 0;
    }

    data.file.writeAll(ptr[0..total]) catch |err| {
        data.failure = .file_write;
        data.write_error = err;
        debug_log.log("curl response file write failure: {s}", .{@errorName(err)});
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
    const total = std.math.mul(usize, size, nmemb) catch {
        data.failure = .response_too_large;
        debug_log.log("curl response limit: part={s} chunk_size_overflow cap={d}", .{ @tagName(data.part), data.max_bytes });
        return 0;
    };
    const remaining = data.max_bytes -| data.list.items.len;
    if (total > remaining) {
        data.failure = .response_too_large;
        debug_log.log(
            "curl response limit: part={s} current={d} chunk={d} cap={d}",
            .{ @tagName(data.part), data.list.items.len, total, data.max_bytes },
        );
        return 0;
    }
    const new_len = data.list.items.len + total;
    data.list.ensureTotalCapacityPrecise(data.allocator, new_len) catch {
        data.failure = .out_of_memory;
        debug_log.log("curl response allocation failure: part={s} current={d} chunk={d}", .{ @tagName(data.part), data.list.items.len, total });
        return 0;
    };
    data.list.appendSliceAssumeCapacity(ptr[0..total]);
    return total;
}

test "transport policy - authenticated requests disable redirects" {
    const policy = transportPolicy(&.{
        "Accept: application/json",
        "authorization: Bearer not-logged",
    });

    try std.testing.expectEqual(RequestMode.authenticated, policy.mode);
    try std.testing.expectEqualStrings("https", std.mem.span(policy.initial_protocols));
    try std.testing.expectEqualStrings("https", std.mem.span(policy.redirect_protocols));
    try std.testing.expectEqual(@as(c_long, 1), policy.no_signal);
    try std.testing.expectEqual(@as(c_long, 1), policy.verify_peer);
    try std.testing.expectEqual(@as(c_long, 2), policy.verify_host);
    try std.testing.expectEqual(@as(c_long, 0), policy.follow_redirects);
    try std.testing.expectEqual(@as(c_long, 0), policy.max_redirects);
    try std.testing.expect(policy.connect_timeout_ms > 0);
    try std.testing.expect(policy.total_timeout_ms >= policy.connect_timeout_ms);
}

test "transport policy - public unauthenticated behavior is explicit" {
    const policy = transportPolicy(&.{"Accept: application/octet-stream"});

    try std.testing.expectEqual(RequestMode.public_unauthenticated, policy.mode);
    try std.testing.expectEqualStrings("https", std.mem.span(policy.initial_protocols));
    try std.testing.expectEqualStrings("https", std.mem.span(policy.redirect_protocols));
    try std.testing.expectEqual(@as(c_long, 1), policy.no_signal);
    try std.testing.expectEqual(@as(c_long, 1), policy.verify_peer);
    try std.testing.expectEqual(@as(c_long, 2), policy.verify_host);
    try std.testing.expectEqual(@as(c_long, 1), policy.follow_redirects);
    try std.testing.expect(policy.max_redirects > 0);
}

test "transport policy - authorization header matching is case insensitive and exact" {
    try std.testing.expect(hasAuthorizationHeader(&.{"  AuThOrIzAtIoN:\tBearer not-logged"}));
    try std.testing.expect(!hasAuthorizationHeader(&.{"Proxy-Authorization: Basic not-logged"}));
    try std.testing.expect(!hasAuthorizationHeader(&.{"X-Authorization: not-logged"}));
    try std.testing.expect(!hasAuthorizationHeader(&.{"Authorization-Like: not-logged"}));
}

test "header capture - retains only the final response block" {
    const allocator = std.testing.allocator;
    var data = HeaderCallbackData.init(allocator, MAX_HEADER_BYTES);
    defer data.write_data.list.deinit(allocator);

    const redirect_status = "HTTP/1.1 302 Found\r\n";
    const redirect_location = "Location: /next\r\n";
    const separator = "\r\n";
    const final_status = "HTTP/1.1 200 OK\r\n";
    const session_header = "Mcp-Session-Id: x\r\n";
    try std.testing.expectEqual(redirect_status.len, headerCallback(redirect_status.ptr, 1, redirect_status.len, @ptrCast(&data)));
    try std.testing.expectEqual(redirect_location.len, headerCallback(redirect_location.ptr, 1, redirect_location.len, @ptrCast(&data)));
    try std.testing.expectEqual(separator.len, headerCallback(separator.ptr, 1, separator.len, @ptrCast(&data)));
    try std.testing.expectEqual(final_status.len, headerCallback(final_status.ptr, 1, final_status.len, @ptrCast(&data)));
    try std.testing.expectEqual(session_header.len, headerCallback(session_header.ptr, 1, session_header.len, @ptrCast(&data)));

    try std.testing.expect(!std.mem.containsAtLeast(u8, data.write_data.list.items, 1, "302 Found"));
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nMcp-Session-Id: x\r\n", data.write_data.list.items);
}

test "request options - response cap is configurable within a hard bound" {
    try (RequestOptions{ .max_response_bytes = 8 }).validate();
    try std.testing.expectError(error.InvalidResponseSizeLimit, (RequestOptions{ .max_response_bytes = 0 }).validate());
    try std.testing.expectError(error.InvalidResponseSizeLimit, (RequestOptions{ .max_response_bytes = MAX_RESPONSE_SIZE_LIMIT + 1 }).validate());
}

test "response ownership - header conversion failure frees owned body" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();
    var response_data = WriteCallbackData.init(allocator, .body, 8);
    var header_data = WriteCallbackData.init(allocator, .headers, 8);
    try response_data.list.ensureTotalCapacityPrecise(allocator, 8);
    try header_data.list.ensureTotalCapacityPrecise(allocator, 8);
    response_data.list.appendSliceAssumeCapacity("body");
    header_data.list.appendSliceAssumeCapacity("head");

    failing_allocator.fail_index = failing_allocator.alloc_index + 1;
    failing_allocator.resize_fail_index = failing_allocator.resize_index;
    try std.testing.expectError(error.OutOfMemory, takePostResult(allocator, 200, &response_data, &header_data));
}

test "write callback - accepts exact cap then aborts before growing" {
    const allocator = std.testing.allocator;
    var data = WriteCallbackData.init(allocator, .body, 4);
    defer data.list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), writeCallback("test".ptr, 1, 4, @ptrCast(&data)));
    try std.testing.expectEqual(@as(usize, 4), data.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), writeCallback("!".ptr, 1, 1, @ptrCast(&data)));
    try std.testing.expectEqual(WriteFailure.response_too_large, data.failure);
    try std.testing.expectEqual(@as(usize, 4), data.list.items.len);
}

test "write callback - allocates no more than response cap" {
    const allocator = std.testing.allocator;
    var data = WriteCallbackData.init(allocator, .body, 5);
    defer data.list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), writeCallback("abc".ptr, 1, 3, @ptrCast(&data)));
    try std.testing.expectEqual(@as(usize, 3), data.list.capacity);
    try std.testing.expectEqual(@as(usize, 2), writeCallback("de".ptr, 1, 2, @ptrCast(&data)));
    try std.testing.expectEqual(@as(usize, 5), data.list.capacity);
}

test "write callback - rejects multiplication overflow before reading input" {
    const allocator = std.testing.allocator;
    var data = WriteCallbackData.init(allocator, .headers, 16);
    defer data.list.deinit(allocator);

    try std.testing.expectEqual(
        @as(usize, 0),
        writeCallback("".ptr, std.math.maxInt(usize), 2, @ptrCast(&data)),
    );
    try std.testing.expectEqual(WriteFailure.response_too_large, data.failure);
    try std.testing.expectEqual(@as(usize, 0), data.list.items.len);
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
