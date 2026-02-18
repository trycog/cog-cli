const std = @import("std");
const c = @import("curl").libcurl;

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

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
) !HttpResponse {
    return fetch(allocator, url, .POST, headers, body);
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
    const handle = c.curl_easy_init() orelse return error.HttpError;
    defer c.curl_easy_cleanup(handle);

    // URL (needs null terminator)
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url_z.ptr);

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
    const res = c.curl_easy_perform(handle);
    if (res != c.CURLE_OK) {
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

    return .{
        .status_code = @intCast(status_code),
        .body = try response_data.list.toOwnedSlice(allocator),
    };
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