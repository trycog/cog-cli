const std = @import("std");
const paths = @import("paths.zig");
const settings_mod = @import("settings.zig");
const debug_log = @import("debug_log.zig");

pub const Config = struct {
    api_key: []const u8,
    url: []const u8,
    brain_url: []const u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        debug_log.log("Config.load: starting", .{});
        const api_key = getApiKey(allocator) catch |err| switch (err) {
            error.MissingApiKey => {
                debug_log.log("Config.load: COG_API_KEY not set", .{});
                printErr("error: COG_API_KEY not set\n");
                return error.Explained;
            },
            else => return err,
        };
        errdefer allocator.free(api_key);
        debug_log.log("Config.load: API key resolved", .{});

        const cog_content = findCogFile(allocator) catch |err| switch (err) {
            error.NoCogFile => {
                debug_log.log("Config.load: no .cog/settings.json found", .{});
                printErr("error: no .cog/settings.json found (searched up to home directory)\n");
                printErr("       Run " ++ "\x1B[2m" ++ "cog init" ++ "\x1B[0m" ++ " to set up a brain.\n");
                return error.Explained;
            },
            else => return err,
        };
        defer allocator.free(cog_content);

        const brain_url = resolveBrainUrl(allocator, cog_content) catch |err| switch (err) {
            error.InvalidCogUrl => {
                debug_log.log("Config.load: invalid URL in settings", .{});
                printErr("error: invalid URL in settings file\n");
                return error.Explained;
            },
            else => return err,
        };
        errdefer allocator.free(brain_url);
        debug_log.log("Config.load: brain_url={s}", .{brain_url});

        const url = extractApiUrl(allocator, brain_url) catch |err| switch (err) {
            error.InvalidCogUrl => {
                printErr("error: invalid URL in settings file\n");
                return error.Explained;
            },
            else => return err,
        };
        debug_log.log("Config.load: api_url={s}", .{url});

        return .{ .api_key = api_key, .url = url, .brain_url = brain_url };
    }

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.url);
        allocator.free(self.brain_url);
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
        debug_log.log("findCogFile: checking {s}/.cog/settings.json", .{current});
        const settings_path = std.fmt.allocPrint(allocator, "{s}/.cog/settings.json", .{current}) catch null;
        const raw = if (settings_path) |sp| blk: {
            defer allocator.free(sp);
            break :blk readFileAtPath(allocator, sp);
        } else null;

        if (raw) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                debug_log.log("findCogFile: found at {s}", .{current});
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

    debug_log.log("findCogFile: not found", .{});
    return error.NoCogFile;
}

fn readFileAtPath(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 4096) catch return null;
}

fn readFileInDir(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8) ?[]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return null;
    defer dir.close();
    const file = dir.openFile(filename, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 4096) catch return null;
}

pub fn resolveUrl(allocator: std.mem.Allocator, cog_content: []const u8) ![]const u8 {
    const brain_url = try resolveBrainUrl(allocator, cog_content);
    defer allocator.free(brain_url);
    return extractApiUrl(allocator, brain_url);
}

pub fn resolveBrainUrl(allocator: std.mem.Allocator, cog_content: []const u8) ![]const u8 {
    // Try JSON format
    if (std.json.parseFromSlice(std.json.Value, allocator, cog_content, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("memory")) |memory| {
                if (memory == .object) {
                    if (memory.object.get("brain")) |brain| {
                        // Flat string format: {"memory": {"brain": "https://host/user/brain"}}
                        if (brain == .string) {
                            return allocator.dupe(u8, brain.string);
                        }
                        // Object format: {"memory": {"brain": {"url": "https://host/user/brain"}}}
                        if (brain == .object) {
                            if (brain.object.get("url")) |url_val| {
                                if (url_val == .string) {
                                    return allocator.dupe(u8, url_val.string);
                                }
                            }
                        }
                    }
                }
            }
        }
        return error.InvalidCogUrl;
    } else |_| {}

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

// ── Brain type resolution ────────────────────────────────────────────────

pub const BrainType = union(enum) {
    local: LocalBrain,
    remote: Config,
    none,

    pub const LocalBrain = struct {
        path: []const u8,
        brain_id: []const u8,
    };

    pub fn deinit(self: BrainType, allocator: std.mem.Allocator) void {
        switch (self) {
            .local => |l| {
                allocator.free(l.path);
                allocator.free(l.brain_id);
            },
            .remote => |r| r.deinit(allocator),
            .none => {},
        }
    }
};

/// Resolve the brain configuration from settings.
/// Returns .local for "file:" URIs, .remote for "https://" URIs, .none otherwise.
pub fn resolveBrain(allocator: std.mem.Allocator) BrainType {
    debug_log.log("resolveBrain: starting", .{});

    const settings = settings_mod.Settings.load(allocator) orelse {
        debug_log.log("resolveBrain: no settings found", .{});
        return .none;
    };
    defer settings.deinit(allocator);

    const mem = settings.memory orelse {
        debug_log.log("resolveBrain: no memory config", .{});
        return .none;
    };
    const brain = mem.brain orelse {
        debug_log.log("resolveBrain: no brain configured", .{});
        return .none;
    };

    const url = brain.url;

    // file: prefix → local SQLite
    if (std.mem.startsWith(u8, url, "file:")) {
        const raw_path = url["file:".len..];
        debug_log.log("resolveBrain: file brain, raw_path={s}", .{raw_path});

        // Resolve relative to project root (directory containing .cog/)
        const project_root = findProjectRoot(allocator) orelse {
            debug_log.log("resolveBrain: cannot find project root", .{});
            return .none;
        };
        defer allocator.free(project_root);

        const abs_path = if (std.fs.path.isAbsolute(raw_path))
            allocator.dupe(u8, raw_path) catch return .none
        else
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, raw_path }) catch return .none;

        const brain_id = allocator.dupe(u8, std.fs.path.basename(project_root)) catch {
            allocator.free(abs_path);
            return .none;
        };

        debug_log.log("resolveBrain: local brain path={s} brain_id={s}", .{ abs_path, brain_id });
        return .{ .local = .{ .path = abs_path, .brain_id = brain_id } };
    }

    // https:// prefix → remote
    if (std.mem.startsWith(u8, url, "https://")) {
        debug_log.log("resolveBrain: remote brain url={s}", .{url});
        const cfg = Config.load(allocator) catch {
            debug_log.log("resolveBrain: remote config load failed", .{});
            return .none;
        };
        return .{ .remote = cfg };
    }

    debug_log.log("resolveBrain: unrecognized brain URL scheme: {s}", .{url});
    return .none;
}

/// Find the project root directory (the one containing .cog/).
fn findProjectRoot(allocator: std.mem.Allocator) ?[]const u8 {
    const cog_dir = paths.findCogDir(allocator) catch return null;
    defer allocator.free(cog_dir);
    // cog_dir is "/path/to/project/.cog" — we want "/path/to/project"
    const root = std.fs.path.dirname(cog_dir) orelse return null;
    return allocator.dupe(u8, root) catch null;
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
        \\{"memory":{"brain":{"url":"https://trycog.ai/user/brain"}}}
    );
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
