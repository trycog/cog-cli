const std = @import("std");
const c = @import("curl").libcurl;
const debug_log = @import("debug_log.zig");

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
