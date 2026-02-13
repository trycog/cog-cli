const std = @import("std");

pub const Config = struct {
    api_key: []const u8,
    url: []const u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const api_key = getApiKey(allocator) catch |err| switch (err) {
            error.MissingApiKey => {
                printErr("error: COG_API_KEY not set\n");
                return error.Explained;
            },
            else => return err,
        };
        errdefer allocator.free(api_key);

        const cog_content = findCogFile(allocator) catch |err| switch (err) {
            error.NoCogFile => {
                printErr("error: no .cog.json file found (searched up to home directory)\n");
                return error.Explained;
            },
            else => return err,
        };
        defer allocator.free(cog_content);

        const url = resolveUrl(allocator, cog_content) catch |err| switch (err) {
            error.InvalidCogUrl => {
                printErr("error: invalid URL in .cog.json file\n");
                return error.Explained;
            },
            else => return err,
        };

        return .{ .api_key = api_key, .url = url };
    }

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.url);
    }
};

pub fn getApiKey(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("COG_API_KEY")) |key| {
        return allocator.dupe(u8, key);
    }
    if (loadEnvValue(allocator, "COG_API_KEY")) |key| {
        return key;
    }
    return error.MissingApiKey;
}

pub fn loadEnvValue(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(".env", .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 65536) catch return null;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
            if (std.mem.eql(u8, key, name)) {
                const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);
                return allocator.dupe(u8, val) catch return null;
            }
        }
    }
    return null;
}

pub fn findCogFile(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoCogFile;

    var current = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(current);

    while (true) {
        // Try .cog.json first, fall back to legacy .cog
        const raw = readFileInDir(allocator, current, ".cog.json") orelse
            readFileInDir(allocator, current, ".cog");

        if (raw) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                return allocator.dupe(u8, trimmed);
            }
        }

        if (std.mem.eql(u8, current, home)) break;

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;
        const new_current = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = new_current;
    }

    return error.NoCogFile;
}

fn readFileInDir(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8) ?[]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return null;
    defer dir.close();
    const file = dir.openFile(filename, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 4096) catch return null;
}

pub fn resolveUrl(allocator: std.mem.Allocator, cog_content: []const u8) ![]const u8 {
    // Try JSON format first: {"brain": {"url": "https://host/user/brain"}}
    if (std.json.parseFromSlice(std.json.Value, allocator, cog_content, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("brain")) |brain| {
                if (brain == .object) {
                    if (brain.object.get("url")) |url_val| {
                        if (url_val == .string) {
                            const url = url_val.string;
                            return extractApiUrl(allocator, url);
                        }
                    }
                }
            }
        }
        return error.InvalidCogUrl;
    } else |_| {}

    // Legacy format: cog://host/user/brain
    const prefix = "cog://";
    if (std.mem.startsWith(u8, cog_content, prefix)) {
        const rest = cog_content[prefix.len..];
        if (rest.len == 0) return error.InvalidCogUrl;
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const host = rest[0..slash];
            const path = rest[slash..];
            return std.fmt.allocPrint(allocator, "https://{s}/api/v1{s}", .{ host, path });
        }
    }

    return error.InvalidCogUrl;
}

fn extractApiUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    // Expect https://host/user/brain — insert /api/v1 after host
    const https_prefix = "https://";
    if (!std.mem.startsWith(u8, url, https_prefix)) return error.InvalidCogUrl;
    const rest = url[https_prefix.len..];
    if (rest.len == 0) return error.InvalidCogUrl;
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const host = rest[0..slash];
        const path = rest[slash..];
        return std.fmt.allocPrint(allocator, "https://{s}/api/v1{s}", .{ host, path });
    }
    return error.InvalidCogUrl;
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

test "resolveUrl JSON format" {
    const allocator = std.testing.allocator;
    const url = try resolveUrl(allocator,
        \\{"brain":{"url":"https://trycog.ai/user/brain"}}
    );
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://trycog.ai/api/v1/user/brain", url);
}

test "resolveUrl legacy cog:// format" {
    const allocator = std.testing.allocator;
    const url = try resolveUrl(allocator, "cog://trycog.ai/user/brain");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://trycog.ai/api/v1/user/brain", url);
}

test "resolveUrl invalid content" {
    const allocator = std.testing.allocator;
    const result = resolveUrl(allocator, "http://example.com");
    try std.testing.expectError(error.InvalidCogUrl, result);
}

test "resolveUrl empty JSON" {
    const allocator = std.testing.allocator;
    const result = resolveUrl(allocator, "{}");
    try std.testing.expectError(error.InvalidCogUrl, result);
}

test "loadEnvValue returns null when no .env file" {
    const allocator = std.testing.allocator;
    const result = loadEnvValue(allocator, "NONEXISTENT_KEY");
    try std.testing.expect(result == null);
}
