const std = @import("std");
const paths = @import("paths.zig");
const debug_log = @import("debug_log.zig");

pub const ToolConfig = struct {
    command: []const u8,
    args: []const []const u8,
};

pub const BrainConfig = struct {
    url: []const u8,
};

pub const DebugConfig = struct {
    timeout: ?i64 = null,
    log: bool = false,
    log_set: bool = false,
};

pub const ObserveConfig = struct {
    timeout: ?i64 = null,
    log: bool = false,
    log_set: bool = false,
    enabled: bool = false,
    enabled_set: bool = false,
    default_backend: ?[]const u8 = null,
};

pub const BootstrapConfig = struct {
    model: ?[]const u8 = null,
};

pub const MemoryConfig = struct {
    brain: ?BrainConfig = null,
    model: ?[]const u8 = null, // legacy: memory.model (deprecated, use memory.bootstrap.model)
    bootstrap: ?BootstrapConfig = null,
};

pub const CodeConfig = struct {
    index: ?[]const []const u8 = null,
    external_roots: ?[]const []const u8 = null,
    indexer: ?ToolConfig = null,
    editor: ?ToolConfig = null,
    creator: ?ToolConfig = null,
    deleter: ?ToolConfig = null,
    renamer: ?ToolConfig = null,
};

pub const Settings = struct {
    memory: ?MemoryConfig = null,
    code: ?CodeConfig = null,
    debug: ?DebugConfig = null,
    observe: ?ObserveConfig = null,

    /// Load merged settings: global (~/.config/cog/settings.json) with local (.cog/settings.json) overrides.
    pub fn load(allocator: std.mem.Allocator) ?Settings {
        debug_log.log("Settings.load: starting", .{});
        const global = loadGlobal(allocator);
        const local = loadLocal(allocator);
        debug_log.log("Settings.load: global={s} local={s}", .{
            if (global != null) "found" else "none",
            if (local != null) "found" else "none",
        });

        if (global == null and local == null) {
            debug_log.log("Settings.load: no settings found", .{});
            return null;
        }

        const result = mergeSettings(
            allocator,
            global orelse Settings{},
            local orelse Settings{},
        );
        debug_log.log("Settings.load: merged global and local settings", .{});
        return result;
    }

    /// Load settings from ~/.config/cog/settings.json.
    fn loadGlobal(allocator: std.mem.Allocator) ?Settings {
        const config_dir = paths.getGlobalConfigDir(allocator) catch return null;
        defer allocator.free(config_dir);

        const path = std.fmt.allocPrint(allocator, "{s}/settings.json", .{config_dir}) catch return null;
        defer allocator.free(path);

        return loadFromPath(allocator, path);
    }

    /// Load settings from .cog/settings.json (local project).
    fn loadLocal(allocator: std.mem.Allocator) ?Settings {
        const cog_dir = paths.findCogDir(allocator) catch return null;
        defer allocator.free(cog_dir);

        const path = std.fmt.allocPrint(allocator, "{s}/settings.json", .{cog_dir}) catch return null;
        defer allocator.free(path);

        return loadFromPath(allocator, path);
    }

    fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?Settings {
        debug_log.log("Settings.loadFromPath: opening {s}", .{path});
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            debug_log.log("Settings.loadFromPath: open {s} failed: {s}", .{ path, @errorName(err) });
            return null;
        };
        defer file.close();

        const data = file.readToEndAlloc(allocator, 64 * 1024) catch |err| {
            debug_log.log("Settings.loadFromPath: read {s} failed: {s}", .{ path, @errorName(err) });
            return null;
        };
        defer allocator.free(data);

        const result = parse(allocator, data);
        if (result == null and data.len > 0) {
            debug_log.log("Settings.loadFromPath: invalid settings in {s}", .{path});
            warnInvalidSettings(path);
        } else {
            debug_log.log("Settings.loadFromPath: parsed {s}", .{path});
        }
        return result;
    }

    fn warnInvalidSettings(path: []const u8) void {
        var buf: [8192]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.writeAll("warning: invalid JSON in ") catch {};
        w.interface.writeAll(path) catch {};
        w.interface.writeAll("\n") catch {};
        w.interface.flush() catch {};
    }

    /// Parse settings from JSON content.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) ?Settings {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        var result: Settings = .{};

        if (obj.get("memory")) |v| {
            result.memory = parseMemoryConfig(allocator, v) catch {
                result.deinit(allocator);
                return null;
            };
        }
        if (obj.get("code")) |v| {
            result.code = parseCodeConfig(allocator, v) catch {
                result.deinit(allocator);
                return null;
            };
        }
        if (obj.get("debug")) |v| {
            result.debug = parseDebugConfig(v);
        }
        if (obj.get("observe")) |v| {
            result.observe = parseObserveConfig(allocator, v);
        }

        return result;
    }

    pub fn deinit(self: *const Settings, allocator: std.mem.Allocator) void {
        if (self.memory) |cfg| freeMemoryConfig(allocator, &cfg);
        if (self.code) |cfg| freeCodeConfig(allocator, &cfg);
        if (self.observe) |cfg| freeObserveConfig(allocator, &cfg);
    }
};

fn parseMemoryConfig(allocator: std.mem.Allocator, value: std.json.Value) !MemoryConfig {
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;

    var result: MemoryConfig = .{};
    errdefer freeMemoryConfig(allocator, &result);

    if (obj.get("brain")) |v| {
        result.brain = try parseBrainConfig(allocator, v);
    }
    // New format: memory.bootstrap.model
    if (obj.get("bootstrap")) |bs| {
        if (bs == .object) {
            if (bs.object.get("model")) |v| {
                if (v == .string) {
                    result.bootstrap = .{ .model = try allocator.dupe(u8, v.string) };
                }
            }
        }
    }
    // Legacy fallback: memory.model
    if (result.bootstrap == null) {
        if (obj.get("model")) |v| {
            if (v == .string) {
                result.model = try allocator.dupe(u8, v.string);
            }
        }
    }
    return result;
}

fn parseCodeConfig(allocator: std.mem.Allocator, value: std.json.Value) !CodeConfig {
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;

    var result: CodeConfig = .{};
    errdefer freeCodeConfig(allocator, &result);

    if (obj.get("index")) |v| {
        result.index = try parseStringList(allocator, v);
    }
    if (obj.get("external_roots")) |v| {
        result.external_roots = try parseStringList(allocator, v);
    }
    if (obj.get("indexer")) |v| {
        result.indexer = try parseToolConfig(allocator, v);
    }
    if (obj.get("editor")) |v| {
        result.editor = try parseToolConfig(allocator, v);
    }
    if (obj.get("creator")) |v| {
        result.creator = try parseToolConfig(allocator, v);
    }
    if (obj.get("deleter")) |v| {
        result.deleter = try parseToolConfig(allocator, v);
    }
    if (obj.get("renamer")) |v| {
        result.renamer = try parseToolConfig(allocator, v);
    }
    return result;
}

fn parseToolConfig(allocator: std.mem.Allocator, value: std.json.Value) !ToolConfig {
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;

    const command_val = obj.get("command") orelse return error.InvalidSettings;
    if (command_val != .string) return error.InvalidSettings;
    const command = try allocator.dupe(u8, command_val.string);
    errdefer allocator.free(command);

    const args_val = obj.get("args") orelse {
        return .{ .command = command, .args = &.{} };
    };
    if (args_val != .array) {
        allocator.free(command);
        return error.InvalidSettings;
    }

    const args = try allocator.alloc([]const u8, args_val.array.items.len);
    var i: usize = 0;
    errdefer {
        for (args[0..i]) |a| allocator.free(a);
        allocator.free(args);
    }

    for (args_val.array.items) |item| {
        if (item != .string) return error.InvalidSettings;
        args[i] = try allocator.dupe(u8, item.string);
        i += 1;
    }

    return .{ .command = command, .args = args };
}

fn parseBrainConfig(allocator: std.mem.Allocator, value: std.json.Value) !BrainConfig {
    // Flat string format: "file:.cog/brain.db" or "https://trycog.ai/user/brain"
    if (value == .string) {
        return .{ .url = try allocator.dupe(u8, value.string) };
    }

    // Legacy object format: {"url": "https://..."}
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;

    const url_val = obj.get("url") orelse return error.InvalidSettings;
    if (url_val != .string) return error.InvalidSettings;
    const url = try allocator.dupe(u8, url_val.string);

    return .{ .url = url };
}

fn freeBrainConfig(allocator: std.mem.Allocator, config: *const BrainConfig) void {
    allocator.free(config.url);
}

fn freeMemoryConfig(allocator: std.mem.Allocator, config: *const MemoryConfig) void {
    if (config.brain) |b| freeBrainConfig(allocator, &b);
    if (config.model) |m| allocator.free(m);
    if (config.bootstrap) |bs| {
        if (bs.model) |m| allocator.free(m);
    }
}

fn freeCodeConfig(allocator: std.mem.Allocator, config: *const CodeConfig) void {
    if (config.index) |idx| freeStringList(allocator, idx);
    if (config.external_roots) |roots| freeStringList(allocator, roots);
    if (config.indexer) |cfg| freeToolConfig(allocator, &cfg);
    if (config.editor) |cfg| freeToolConfig(allocator, &cfg);
    if (config.creator) |cfg| freeToolConfig(allocator, &cfg);
    if (config.deleter) |cfg| freeToolConfig(allocator, &cfg);
    if (config.renamer) |cfg| freeToolConfig(allocator, &cfg);
}

fn parseDebugConfig(value: std.json.Value) ?DebugConfig {
    // "debug": true  →  enable debug logging
    if (value == .bool) return .{ .log = value.bool, .log_set = true };

    if (value != .object) return null;
    const obj = value.object;

    var result: DebugConfig = .{};
    if (obj.get("timeout")) |v| {
        if (v == .integer) result.timeout = v.integer;
    }
    if (obj.get("log")) |v| {
        if (v == .bool) {
            result.log = v.bool;
            result.log_set = true;
        }
    }
    return result;
}

fn mergeSettings(allocator: std.mem.Allocator, global: Settings, local: Settings) Settings {
    debug_log.log("Settings.merge: applying local overrides", .{});
    return .{
        .memory = mergeMemoryConfig(allocator, local.memory, global.memory),
        .code = mergeCodeConfig(allocator, local.code, global.code),
        .debug = mergeDebugConfig(local.debug, global.debug),
        .observe = mergeObserveConfig(allocator, local.observe, global.observe),
    };
}

fn mergeMemoryConfig(allocator: std.mem.Allocator, local: ?MemoryConfig, global: ?MemoryConfig) ?MemoryConfig {
    const l = local orelse return global;
    const g = global orelse return local;

    var result: MemoryConfig = .{};
    result.brain = l.brain orelse g.brain;
    if (l.brain != null) {
        if (g.brain) |gb| freeBrainConfig(allocator, &gb);
    }

    // memory.model and memory.bootstrap.model configure the same setting in
    // legacy and current forms. A model specified locally overrides either
    // representation globally.
    const local_has_model = l.model != null or (l.bootstrap != null and l.bootstrap.?.model != null);
    if (local_has_model) {
        result.model = l.model;
        result.bootstrap = l.bootstrap;
        if (g.model) |gm| allocator.free(gm);
        if (g.bootstrap) |gbs| {
            if (gbs.model) |gm| allocator.free(gm);
        }
    } else {
        result.model = g.model;
        result.bootstrap = g.bootstrap;
    }

    return result;
}

fn mergeCodeConfig(allocator: std.mem.Allocator, local: ?CodeConfig, global: ?CodeConfig) ?CodeConfig {
    const l = local orelse return global;
    const g = global orelse return local;

    var result: CodeConfig = .{};

    result.index = l.index orelse g.index;
    if (l.index != null) {
        if (g.index) |gi| freeStringList(allocator, gi);
    }

    result.external_roots = l.external_roots orelse g.external_roots;
    if (l.external_roots != null) {
        if (g.external_roots) |roots| freeStringList(allocator, roots);
    }

    result.indexer = l.indexer orelse g.indexer;
    if (l.indexer != null) {
        if (g.indexer) |gi| freeToolConfig(allocator, &gi);
    }

    result.editor = l.editor orelse g.editor;
    if (l.editor != null) {
        if (g.editor) |ge| freeToolConfig(allocator, &ge);
    }

    result.creator = l.creator orelse g.creator;
    if (l.creator != null) {
        if (g.creator) |gc| freeToolConfig(allocator, &gc);
    }

    result.deleter = l.deleter orelse g.deleter;
    if (l.deleter != null) {
        if (g.deleter) |gd| freeToolConfig(allocator, &gd);
    }

    result.renamer = l.renamer orelse g.renamer;
    if (l.renamer != null) {
        if (g.renamer) |gr| freeToolConfig(allocator, &gr);
    }

    return result;
}

fn mergeDebugConfig(local: ?DebugConfig, global: ?DebugConfig) ?DebugConfig {
    const l = local orelse return global;
    const g = global orelse return local;
    return .{
        .timeout = l.timeout orelse g.timeout,
        .log = if (l.log_set) l.log else g.log,
        .log_set = l.log_set or g.log_set,
    };
}

fn parseObserveConfig(allocator: std.mem.Allocator, value: std.json.Value) ?ObserveConfig {
    if (value != .object) return null;
    const obj = value.object;

    var result: ObserveConfig = .{};
    if (obj.get("timeout")) |v| {
        if (v == .integer) result.timeout = v.integer;
    }
    if (obj.get("log")) |v| {
        if (v == .bool) {
            result.log = v.bool;
            result.log_set = true;
        }
    }
    if (obj.get("enabled")) |v| {
        if (v == .bool) {
            result.enabled = v.bool;
            result.enabled_set = true;
        }
    }
    if (obj.get("default_backend")) |v| {
        if (v == .string) result.default_backend = allocator.dupe(u8, v.string) catch null;
    }
    return result;
}

fn mergeObserveConfig(allocator: std.mem.Allocator, local: ?ObserveConfig, global: ?ObserveConfig) ?ObserveConfig {
    const l = local orelse return global;
    const g = global orelse return local;

    // Free the losing default_backend
    if (l.default_backend != null) {
        if (g.default_backend) |gb| allocator.free(gb);
    }

    return .{
        .timeout = l.timeout orelse g.timeout,
        .log = if (l.log_set) l.log else g.log,
        .log_set = l.log_set or g.log_set,
        .enabled = if (l.enabled_set) l.enabled else g.enabled,
        .enabled_set = l.enabled_set or g.enabled_set,
        .default_backend = l.default_backend orelse g.default_backend,
    };
}

fn freeObserveConfig(allocator: std.mem.Allocator, config: *const ObserveConfig) void {
    if (config.default_backend) |db| allocator.free(db);
}

fn freeToolConfig(allocator: std.mem.Allocator, config: *const ToolConfig) void {
    for (config.args) |arg| {
        allocator.free(arg);
    }
    if (config.args.len > 0) {
        allocator.free(config.args);
    }
    allocator.free(config.command);
}

fn parseStringList(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return error.InvalidSettings;

    const items = value.array.items;
    const patterns = try allocator.alloc([]const u8, items.len);
    var i: usize = 0;
    errdefer {
        for (patterns[0..i]) |p| allocator.free(p);
        allocator.free(patterns);
    }

    for (items) |item| {
        if (item != .string) return error.InvalidSettings;
        patterns[i] = try allocator.dupe(u8, item.string);
        i += 1;
    }

    return patterns;
}

fn freeStringList(allocator: std.mem.Allocator, patterns: []const []const u8) void {
    for (patterns) |p| allocator.free(p);
    allocator.free(patterns);
}

/// Substitute placeholders in a single arg string.
/// Supported placeholders: {output}, {file}, {old}, {new}, {content}
pub fn substitutePlaceholder(allocator: std.mem.Allocator, template: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    // Count occurrences
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < template.len) {
        if (std.mem.startsWith(u8, template[pos..], key)) {
            count += 1;
            pos += key.len;
        } else {
            pos += 1;
        }
    }

    if (count == 0) return try allocator.dupe(u8, template);

    const new_len = template.len - (count * key.len) + (count * value.len);
    const result = try allocator.alloc(u8, new_len);
    var write_pos: usize = 0;
    var read_pos: usize = 0;

    while (read_pos < template.len) {
        if (std.mem.startsWith(u8, template[read_pos..], key)) {
            @memcpy(result[write_pos..][0..value.len], value);
            write_pos += value.len;
            read_pos += key.len;
        } else {
            result[write_pos] = template[read_pos];
            write_pos += 1;
            read_pos += 1;
        }
    }

    return result;
}

pub const Substitution = struct {
    key: []const u8,
    value: []const u8,
};

/// Substitute all known placeholders in an args array. Caller owns returned slice.
pub fn substituteArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    subs: []const Substitution,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, args.len);
    var i: usize = 0;
    errdefer {
        for (result[0..i]) |a| allocator.free(a);
        allocator.free(result);
    }

    for (args) |arg| {
        var current: []const u8 = try allocator.dupe(u8, arg);
        for (subs) |sub| {
            const next = substitutePlaceholder(allocator, current, sub.key, sub.value) catch {
                allocator.free(current);
                return error.SubstitutionFailed;
            };
            allocator.free(current);
            current = next;
        }
        result[i] = current;
        i += 1;
    }

    return result;
}

pub fn freeSubstitutedArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |a| allocator.free(a);
    allocator.free(args);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse settings with indexer and editor" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"indexer":{"command":"scip-zig","args":["--root-path",".","--output","{output}"]},"editor":{"command":"sed","args":["-i","","s/{old}/{new}/g","{file}"]}}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    const code = settings.code.?;
    try std.testing.expectEqualStrings("scip-zig", code.indexer.?.command);
    try std.testing.expectEqual(@as(usize, 4), code.indexer.?.args.len);
    try std.testing.expectEqualStrings("--output", code.indexer.?.args[2]);
    try std.testing.expectEqualStrings("{output}", code.indexer.?.args[3]);

    try std.testing.expectEqualStrings("sed", code.editor.?.command);
    try std.testing.expectEqual(@as(usize, 4), code.editor.?.args.len);
}

test "parse settings with only indexer" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"indexer":{"command":"scip-go","args":["--output","{output}"]}}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.code != null);
    try std.testing.expect(settings.code.?.indexer != null);
    try std.testing.expect(settings.code.?.editor == null);
}

test "parse settings empty object" {
    const allocator = std.testing.allocator;
    const json = "{}";
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.code == null);
    try std.testing.expect(settings.memory == null);
}

test "parse settings invalid json returns null" {
    const allocator = std.testing.allocator;
    const result = Settings.parse(allocator, "not json");
    try std.testing.expect(result == null);
}

test "parse settings command without args" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"indexer":{"command":"my-indexer"}}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expectEqualStrings("my-indexer", settings.code.?.indexer.?.command);
    try std.testing.expectEqual(@as(usize, 0), settings.code.?.indexer.?.args.len);
}

test "parse settings with all CRUD tool configs" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"creator":{"command":"touch","args":["{file}"]},"deleter":{"command":"rm","args":["{file}"]},"renamer":{"command":"mv","args":["{old}","{new}"]}}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    const code = settings.code.?;
    try std.testing.expect(code.creator != null);
    try std.testing.expectEqualStrings("touch", code.creator.?.command);
    try std.testing.expect(code.deleter != null);
    try std.testing.expectEqualStrings("rm", code.deleter.?.command);
    try std.testing.expect(code.renamer != null);
    try std.testing.expectEqualStrings("mv", code.renamer.?.command);
}

test "substitutePlaceholder basic" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "--output={output}", "{output}", "/path/to/index.scip");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("--output=/path/to/index.scip", result);
}

test "substitutePlaceholder no match" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "--verbose", "{output}", "/path");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("--verbose", result);
}

test "substitutePlaceholder exact match" {
    const allocator = std.testing.allocator;
    const result = try substitutePlaceholder(allocator, "{file}", "{file}", "src/main.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("src/main.zig", result);
}

test "parse settings with debug timeout" {
    const allocator = std.testing.allocator;
    const json =
        \\{"debug":{"timeout":300000}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.debug != null);
    try std.testing.expectEqual(@as(i64, 300000), settings.debug.?.timeout.?);
}

test "parse settings debug without timeout uses null" {
    const allocator = std.testing.allocator;
    const json =
        \\{"debug":{}}
    ;
    const settings = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer settings.deinit(allocator);

    try std.testing.expect(settings.debug != null);
    try std.testing.expect(settings.debug.?.timeout == null);
}

test "substituteArgs multiple placeholders" {
    const allocator = std.testing.allocator;
    const args: []const []const u8 = &.{ "-i", "", "s/{old}/{new}/g", "{file}" };
    const subs: []const Substitution = &.{
        .{ .key = "{old}", .value = "hello" },
        .{ .key = "{new}", .value = "world" },
        .{ .key = "{file}", .value = "test.txt" },
    };
    const result = try substituteArgs(allocator, args, subs);
    defer freeSubstitutedArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("-i", result[0]);
    try std.testing.expectEqualStrings("", result[1]);
    try std.testing.expectEqualStrings("s/hello/world/g", result[2]);
    try std.testing.expectEqualStrings("test.txt", result[3]);
}

test "parse settings with index patterns" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"index":["**/*.ts","**/*.go","src/**/*.zig"]}}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expect(s.code != null);
    const idx = s.code.?.index.?;
    try std.testing.expectEqual(@as(usize, 3), idx.len);
    try std.testing.expectEqualStrings("**/*.ts", idx[0]);
    try std.testing.expectEqualStrings("**/*.go", idx[1]);
    try std.testing.expectEqualStrings("src/**/*.zig", idx[2]);
}

test "parse settings without index has null" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"indexer":{"command":"scip-go","args":["--output","{output}"]}}}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expect(s.code.?.index == null);
}

test "parse settings with empty index array" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"index":[]}}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expect(s.code != null);
    try std.testing.expect(s.code.?.index != null);
    try std.testing.expectEqual(@as(usize, 0), s.code.?.index.?.len);
}

test "parse settings index with non-string element returns null" {
    const allocator = std.testing.allocator;
    const json =
        \\{"code":{"index":["**/*.ts", 42]}}
    ;
    const result = Settings.parse(allocator, json);
    try std.testing.expect(result == null);
}

test "parse settings with memory brain" {
    const allocator = std.testing.allocator;
    const json =
        \\{"memory":{"brain":{"url":"https://trycog.ai/user/brain"}}}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expect(s.memory != null);
    try std.testing.expect(s.memory.?.brain != null);
    try std.testing.expectEqualStrings("https://trycog.ai/user/brain", s.memory.?.brain.?.url);
}

test "parse settings with memory brain flat string (file:)" {
    const allocator = std.testing.allocator;
    const json =
        \\{"memory":{"brain":"file:.cog/brain.db"}}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expect(s.memory != null);
    try std.testing.expect(s.memory.?.brain != null);
    try std.testing.expectEqualStrings("file:.cog/brain.db", s.memory.?.brain.?.url);
}

test "parse settings with memory brain flat string (https://)" {
    const allocator = std.testing.allocator;
    const json =
        \\{"memory":{"brain":"https://trycog.ai/user/brain"}}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expect(s.memory != null);
    try std.testing.expect(s.memory.?.brain != null);
    try std.testing.expectEqualStrings("https://trycog.ai/user/brain", s.memory.?.brain.?.url);
}

test "parse settings with mergeable fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "memory": {"bootstrap": {"model": "bootstrap-model"}},
        \\  "code": {"external_roots": ["../shared", "/opt/generated"]},
        \\  "debug": {"timeout": 1000, "log": true},
        \\  "observe": {"enabled": false}
        \\}
    ;
    const s = Settings.parse(allocator, json) orelse return error.ParseFailed;
    defer s.deinit(allocator);

    try std.testing.expectEqualStrings("bootstrap-model", s.memory.?.bootstrap.?.model.?);
    try std.testing.expectEqual(@as(usize, 2), s.code.?.external_roots.?.len);
    try std.testing.expectEqualStrings("../shared", s.code.?.external_roots.?[0]);
    try std.testing.expectEqualStrings("/opt/generated", s.code.?.external_roots.?[1]);
    try std.testing.expect(s.debug.?.log);
    try std.testing.expect(!s.observe.?.enabled);
}

test "merge settings inherits global fields and applies local overrides" {
    const allocator = std.testing.allocator;
    const global_json =
        \\{
        \\  "memory": {"brain": "file:global.db", "bootstrap": {"model": "global-model"}},
        \\  "code": {"index": ["src/**/*.zig"], "external_roots": ["../global"]},
        \\  "debug": {"timeout": 1000, "log": true},
        \\  "observe": {"timeout": 2000, "log": true, "enabled": true, "default_backend": "global"}
        \\}
    ;
    const local_json =
        \\{
        \\  "memory": {"brain": "file:local.db"},
        \\  "code": {"external_roots": ["../local"]},
        \\  "debug": {"log": false},
        \\  "observe": {"log": false, "enabled": false, "default_backend": "local"}
        \\}
    ;

    const global = Settings.parse(allocator, global_json) orelse return error.ParseFailed;
    const local = Settings.parse(allocator, local_json) orelse return error.ParseFailed;
    const merged = mergeSettings(allocator, global, local);
    defer merged.deinit(allocator);

    try std.testing.expectEqualStrings("file:local.db", merged.memory.?.brain.?.url);
    try std.testing.expectEqualStrings("global-model", merged.memory.?.bootstrap.?.model.?);
    try std.testing.expectEqualStrings("src/**/*.zig", merged.code.?.index.?[0]);
    try std.testing.expectEqualStrings("../local", merged.code.?.external_roots.?[0]);
    try std.testing.expectEqual(@as(i64, 1000), merged.debug.?.timeout.?);
    try std.testing.expect(!merged.debug.?.log);
    try std.testing.expectEqual(@as(i64, 2000), merged.observe.?.timeout.?);
    try std.testing.expect(!merged.observe.?.log);
    try std.testing.expect(!merged.observe.?.enabled);
    try std.testing.expectEqualStrings("local", merged.observe.?.default_backend.?);
}

test "merge settings local legacy memory model overrides global bootstrap model" {
    const allocator = std.testing.allocator;
    const global = Settings.parse(allocator,
        \\{"memory":{"bootstrap":{"model":"global-bootstrap"}}}
    ) orelse return error.ParseFailed;
    const local = Settings.parse(allocator,
        \\{"memory":{"model":"local-legacy"}}
    ) orelse return error.ParseFailed;

    const merged = mergeSettings(allocator, global, local);
    defer merged.deinit(allocator);

    try std.testing.expect(merged.memory.?.bootstrap == null);
    try std.testing.expectEqualStrings("local-legacy", merged.memory.?.model.?);
}

test "merge settings local bootstrap model overrides global legacy model" {
    const allocator = std.testing.allocator;
    const global = Settings.parse(allocator,
        \\{"memory":{"model":"global-legacy"}}
    ) orelse return error.ParseFailed;
    const local = Settings.parse(allocator,
        \\{"memory":{"bootstrap":{"model":"local-bootstrap"}}}
    ) orelse return error.ParseFailed;

    const merged = mergeSettings(allocator, global, local);
    defer merged.deinit(allocator);

    try std.testing.expect(merged.memory.?.model == null);
    try std.testing.expectEqualStrings("local-bootstrap", merged.memory.?.bootstrap.?.model.?);
}

test "merge settings empty local external roots overrides global roots" {
    const allocator = std.testing.allocator;
    const global = Settings.parse(allocator,
        \\{"code":{"external_roots":["../global"]}}
    ) orelse return error.ParseFailed;
    const local = Settings.parse(allocator,
        \\{"code":{"external_roots":[]}}
    ) orelse return error.ParseFailed;

    const merged = mergeSettings(allocator, global, local);
    defer merged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), merged.code.?.external_roots.?.len);
}

test "parse settings cleans memory allocations after later parse failure" {
    const allocator = std.testing.allocator;
    const result = Settings.parse(allocator,
        \\{"memory":{"brain":"file:brain.db"},"code":{"index":[42]}}
    );
    try std.testing.expect(result == null);
}
