const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const config_mod = @import("config.zig");
const client = @import("client.zig");
const tui = @import("tui.zig");

const Config = config_mod.Config;

// ── Helpers ─────────────────────────────────────────────────────────────

fn printStdout(text: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(text) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn findFlag(args: []const [:0]const u8, flag: []const u8) ?[:0]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 < args.len) return args[i + 1];
        }
    }
    return null;
}

fn findRepeatedFlag(allocator: std.mem.Allocator, args: []const [:0]const u8, flag: []const u8) !std.ArrayListUnmanaged([:0]const u8) {
    var list: std.ArrayListUnmanaged([:0]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 < args.len) {
                i += 1;
                try list.append(allocator, args[i]);
            }
        }
    }
    return list;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

/// Parse a compound value like "target:foo,predicate:bar" into key-value pairs.
/// Returns a list of key=value pairs split on ',' then on first ':'.
const KV = struct { key: []const u8, value: []const u8 };

fn parseCompoundValue(value: []const u8, out: []KV) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |part| {
        if (count >= out.len) break;
        if (std.mem.indexOfScalar(u8, part, ':')) |colon| {
            out[count] = .{ .key = part[0..colon], .value = part[colon + 1 ..] };
            count += 1;
        }
    }
    return count;
}

fn printErrFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printErr(msg);
}

fn readStdinLine(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [1024]u8 = undefined;
    const n = std.posix.read(std.fs.File.stdin().handle, &buf) catch {
        printErr("error: failed to read input\n");
        return error.Explained;
    };
    if (n == 0) {
        printErr("error: no input received\n");
        return error.Explained;
    }
    var line = buf[0..n];
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return allocator.dupe(u8, line);
}

fn callAndPrint(allocator: std.mem.Allocator, cfg: Config, tool_name: []const u8, args_json: []const u8) !void {
    const result = try client.call(allocator, cfg.url, cfg.api_key, tool_name, args_json);
    defer allocator.free(result);
    printStdout(result);
}

// ── JSON building helpers ───────────────────────────────────────────────

fn jsonEmpty(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "{}");
}

const JsonBuilder = struct {
    aw: Writer.Allocating,
    s: Stringify,

    fn init(allocator: std.mem.Allocator) JsonBuilder {
        return .{
            .aw = .init(allocator),
            .s = undefined,
        };
    }

    fn deinit(self: *JsonBuilder) void {
        self.aw.deinit();
    }

    fn begin(self: *JsonBuilder) !void {
        // Fix writer pointer now that self is at its final address
        self.s = .{ .writer = &self.aw.writer };
        try self.s.beginObject();
    }

    fn end(self: *JsonBuilder) !void {
        try self.s.endObject();
    }

    fn field(self: *JsonBuilder, name: []const u8) !void {
        try self.s.objectField(name);
    }

    fn string(self: *JsonBuilder, value: []const u8) !void {
        try self.s.write(value);
    }

    fn int(self: *JsonBuilder, value: i64) !void {
        try self.s.write(value);
    }

    fn boolean(self: *JsonBuilder, value: bool) !void {
        try self.s.write(value);
    }

    fn toOwnedSlice(self: *JsonBuilder) ![]const u8 {
        return self.aw.toOwnedSlice();
    }
};

// ── Read Commands ───────────────────────────────────────────────────────

pub fn recall(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog recall <query> [--limit N] [--predicate-filter P]... [--exclude-predicate P]... [--created-after DATE] [--created-before DATE] [--no-strengthen]\n");
        return error.Explained;
    }

    const query: []const u8 = args[0];
    const limit = findFlag(args[1..], "--limit");
    const created_after = findFlag(args[1..], "--created-after");
    const created_before = findFlag(args[1..], "--created-before");
    const no_strengthen = hasFlag(args[1..], "--no-strengthen");

    var pred_filters = try findRepeatedFlag(allocator, args[1..], "--predicate-filter");
    defer pred_filters.deinit(allocator);

    var exclude_preds = try findRepeatedFlag(allocator, args[1..], "--exclude-predicate");
    defer exclude_preds.deinit(allocator);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("query");
    try s.write(query);

    if (limit) |l| {
        try s.objectField("limit");
        const n = std.fmt.parseInt(i64, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        };
        try s.write(n);
    }

    if (pred_filters.items.len > 0) {
        try s.objectField("predicate_filter");
        try s.beginArray();
        for (pred_filters.items) |p| {
            try s.write(@as([]const u8, p));
        }
        try s.endArray();
    }

    if (exclude_preds.items.len > 0) {
        try s.objectField("exclude_predicates");
        try s.beginArray();
        for (exclude_preds.items) |p| {
            try s.write(@as([]const u8, p));
        }
        try s.endArray();
    }

    if (created_after) |d| {
        try s.objectField("created_after");
        try s.write(@as([]const u8, d));
    }

    if (created_before) |d| {
        try s.objectField("created_before");
        try s.write(@as([]const u8, d));
    }

    if (no_strengthen) {
        try s.objectField("strengthen");
        try s.write(false);
    }

    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "recall", args_json);
}

pub fn get(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog get <engram-id>\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("engram_id");
    try s.write(@as([]const u8, args[0]));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "get", args_json);
}

pub fn connections(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog connections <engram-id> [--direction incoming|outgoing|both]\n");
        return error.Explained;
    }

    const direction = findFlag(args[1..], "--direction");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("engram_id");
    try s.write(@as([]const u8, args[0]));
    if (direction) |d| {
        try s.objectField("direction");
        try s.write(@as([]const u8, d));
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "connections", args_json);
}

pub fn trace(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len < 2 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog trace <from-id> <to-id>\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("from_id");
    try s.write(@as([]const u8, args[0]));
    try s.objectField("to_id");
    try s.write(@as([]const u8, args[1]));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "trace", args_json);
}

pub fn bulkRecall(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog bulk-recall <query1> <query2> ... [--limit N]\n");
        return error.Explained;
    }

    const limit = findFlag(args, "--limit");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("queries");
    try s.beginArray();
    for (args) |arg| {
        const a: []const u8 = arg;
        if (std.mem.eql(u8, a, "--limit")) continue;
        // skip the value after --limit
        if (limit) |l| {
            if (std.mem.eql(u8, a, l)) continue;
        }
        if (std.mem.startsWith(u8, a, "--")) continue;
        try s.write(a);
    }
    try s.endArray();
    if (limit) |l| {
        try s.objectField("limit");
        const n = std.fmt.parseInt(i64, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        };
        try s.write(n);
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "bulk_recall", args_json);
}

pub fn listShortTerm(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const limit = findFlag(args, "--limit");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (limit) |l| {
        try s.objectField("limit");
        const n = std.fmt.parseInt(i64, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        };
        try s.write(n);
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "list_short_term", args_json);
}

pub fn stale(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const level = findFlag(args, "--level");
    const limit = findFlag(args, "--limit");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (level) |l| {
        try s.objectField("level");
        try s.write(@as([]const u8, l));
    }
    if (limit) |l| {
        try s.objectField("limit");
        const n = std.fmt.parseInt(i64, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        };
        try s.write(n);
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "stale", args_json);
}

pub fn stats(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    _ = args;
    const args_json = try jsonEmpty(allocator);
    defer allocator.free(args_json);
    try callAndPrint(allocator, cfg, "stats", args_json);
}

pub fn orphans(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const limit = findFlag(args, "--limit");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (limit) |l| {
        try s.objectField("limit");
        const n = std.fmt.parseInt(i64, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        };
        try s.write(n);
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "orphans", args_json);
}

pub fn connectivity(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    _ = args;
    const args_json = try jsonEmpty(allocator);
    defer allocator.free(args_json);
    try callAndPrint(allocator, cfg, "connectivity", args_json);
}

pub fn listTerms(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const limit = findFlag(args, "--limit");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    if (limit) |l| {
        try s.objectField("limit");
        const n = std.fmt.parseInt(i64, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        };
        try s.write(n);
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "list_terms", args_json);
}

// ── Write Commands ──────────────────────────────────────────────────────

pub fn learn(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const term = findFlag(args, "--term") orelse {
        printErr("error: --term is required\n");
        return error.Explained;
    };
    const definition = findFlag(args, "--definition") orelse {
        printErr("error: --definition is required\n");
        return error.Explained;
    };
    const long_term = hasFlag(args, "--long-term");

    var associates = try findRepeatedFlag(allocator, args, "--associate");
    defer associates.deinit(allocator);

    var chains = try findRepeatedFlag(allocator, args, "--chain");
    defer chains.deinit(allocator);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("term");
    try s.write(@as([]const u8, term));
    try s.objectField("definition");
    try s.write(@as([]const u8, definition));

    if (long_term) {
        try s.objectField("long_term");
        try s.write(true);
    }

    if (associates.items.len > 0) {
        try s.objectField("associations");
        try s.beginArray();
        for (associates.items) |assoc_str| {
            var kvs: [4]KV = undefined;
            const count = parseCompoundValue(assoc_str, &kvs);
            try s.beginObject();
            for (kvs[0..count]) |kv| {
                try s.objectField(kv.key);
                try s.write(kv.value);
            }
            try s.endObject();
        }
        try s.endArray();
    }

    if (chains.items.len > 0) {
        try s.objectField("chain_to");
        try s.beginArray();
        for (chains.items) |chain_str| {
            var kvs: [4]KV = undefined;
            const count = parseCompoundValue(chain_str, &kvs);
            try s.beginObject();
            for (kvs[0..count]) |kv| {
                try s.objectField(kv.key);
                try s.write(kv.value);
            }
            try s.endObject();
        }
        try s.endArray();
    }

    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "learn", args_json);
}

pub fn associate(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const source = findFlag(args, "--source") orelse {
        printErr("error: --source is required\n");
        return error.Explained;
    };
    const target = findFlag(args, "--target") orelse {
        printErr("error: --target is required\n");
        return error.Explained;
    };
    const predicate = findFlag(args, "--predicate");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("source_term");
    try s.write(@as([]const u8, source));
    try s.objectField("target_term");
    try s.write(@as([]const u8, target));
    if (predicate) |p| {
        try s.objectField("predicate");
        try s.write(@as([]const u8, p));
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "associate", args_json);
}

pub fn bulkLearn(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    var items = try findRepeatedFlag(allocator, args, "--item");
    defer items.deinit(allocator);

    if (items.items.len == 0) {
        printErr("error: at least one --item is required\n");
        return error.Explained;
    }

    const memory = findFlag(args, "--memory");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("items");
    try s.beginArray();
    for (items.items) |item_str| {
        var kvs: [4]KV = undefined;
        const count = parseCompoundValue(item_str, &kvs);
        try s.beginObject();
        for (kvs[0..count]) |kv| {
            try s.objectField(kv.key);
            try s.write(kv.value);
        }
        try s.endObject();
    }
    try s.endArray();
    if (memory) |m| {
        try s.objectField("memory_term");
        try s.write(@as([]const u8, m));
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "bulk_learn", args_json);
}

pub fn bulkAssociate(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    var links = try findRepeatedFlag(allocator, args, "--link");
    defer links.deinit(allocator);

    if (links.items.len == 0) {
        printErr("error: at least one --link is required\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("associations");
    try s.beginArray();
    for (links.items) |link_str| {
        var kvs: [4]KV = undefined;
        const count = parseCompoundValue(link_str, &kvs);
        try s.beginObject();
        for (kvs[0..count]) |kv| {
            if (std.mem.eql(u8, kv.key, "source")) {
                try s.objectField("source_term");
            } else if (std.mem.eql(u8, kv.key, "target")) {
                try s.objectField("target_term");
            } else {
                try s.objectField(kv.key);
            }
            try s.write(kv.value);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "bulk_associate", args_json);
}

pub fn update(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog update <engram-id> [--term TERM] [--definition DEF]\n");
        return error.Explained;
    }

    const term = findFlag(args[1..], "--term");
    const definition = findFlag(args[1..], "--definition");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("engram_id");
    try s.write(@as([]const u8, args[0]));
    if (term) |t| {
        try s.objectField("term");
        try s.write(@as([]const u8, t));
    }
    if (definition) |d| {
        try s.objectField("definition");
        try s.write(@as([]const u8, d));
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "update", args_json);
}

pub fn unlink(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog unlink <synapse-id>\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("synapse_id");
    try s.write(@as([]const u8, args[0]));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "unlink", args_json);
}

pub fn refactor(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const term = findFlag(args, "--term") orelse {
        printErr("error: --term is required\n");
        return error.Explained;
    };
    const definition = findFlag(args, "--definition") orelse {
        printErr("error: --definition is required\n");
        return error.Explained;
    };

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("term");
    try s.write(@as([]const u8, term));
    try s.objectField("definition");
    try s.write(@as([]const u8, definition));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "refactor", args_json);
}

pub fn deprecate(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const term = findFlag(args, "--term") orelse {
        printErr("error: --term is required\n");
        return error.Explained;
    };

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("term");
    try s.write(@as([]const u8, term));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "deprecate", args_json);
}

pub fn reinforce(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog reinforce <engram-id>\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("engram_id");
    try s.write(@as([]const u8, args[0]));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "reinforce", args_json);
}

pub fn flush(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog flush <engram-id>\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("engram_id");
    try s.write(@as([]const u8, args[0]));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "flush", args_json);
}

pub fn verify(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        printErr("Usage: cog verify <synapse-id>\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("synapse_id");
    try s.write(@as([]const u8, args[0]));
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "verify", args_json);
}

pub fn meld(allocator: std.mem.Allocator, args: []const [:0]const u8, cfg: Config) !void {
    const target = findFlag(args, "--target") orelse {
        printErr("error: --target is required\n");
        return error.Explained;
    };
    const description = findFlag(args, "--description");

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("target");
    try s.write(@as([]const u8, target));
    if (description) |d| {
        try s.objectField("description");
        try s.write(@as([]const u8, d));
    }
    try s.endObject();
    const args_json = try aw.toOwnedSlice();
    defer allocator.free(args_json);

    try callAndPrint(allocator, cfg, "meld", args_json);
}

// ── Init Command ────────────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printErr("Usage: cog init [--host HOST]\n\nInteractively configure a .cog.json file and system prompt for the current directory.\n");
        return;
    }

    const host: []const u8 = findFlag(args, "--host") orelse "trycog.ai";

    tui.header();

    // Get API key
    const api_key = config_mod.getApiKey(allocator) catch {
        printErr("error: COG_API_KEY not set. Set it in your environment or .env file.\n");
        return error.Explained;
    };
    defer allocator.free(api_key);

    // Verify API key
    printErr("  Verifying API key... ");
    const verify_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/verify", .{host});
    defer allocator.free(verify_url);

    const verify_body = client.httpGet(allocator, verify_url, api_key) catch {
        printErr("\n  error: failed to verify API key (check COG_API_KEY and host)\n");
        return error.Explained;
    };
    defer allocator.free(verify_body);

    // Parse {"data": {"username": "..."}}
    const verify_parsed = json.parseFromSlice(json.Value, allocator, verify_body, .{}) catch {
        printErr("\n  error: invalid response from server\n");
        return error.Explained;
    };
    defer verify_parsed.deinit();

    const username = blk: {
        if (verify_parsed.value == .object) {
            if (verify_parsed.value.object.get("data")) |data| {
                if (data == .object) {
                    if (data.object.get("username")) |u| {
                        if (u == .string) break :blk u.string;
                    }
                }
            }
        }
        printErr("\n  error: unexpected response from verify endpoint\n");
        return error.Explained;
    };
    tui.checkmark();
    printErr(" ");
    printErr(username);
    printErr("\n\n");

    // Check if .cog.json already exists
    const cog_exists = blk: {
        const f = std.fs.cwd().openFile(".cog.json", .{}) catch break :blk false;
        f.close();
        break :blk true;
    };
    const write_cog = if (cog_exists)
        try tui.confirm(".cog.json already exists. Overwrite?")
    else
        true;

    if (write_cog) {
        // List brains via REST API
        const list_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/brains/list", .{host});
        defer allocator.free(list_url);

        const brains_text = try client.post(allocator, list_url, api_key, "{}");
        defer allocator.free(brains_text);

        const accounts_parsed = json.parseFromSlice(json.Value, allocator, brains_text, .{}) catch {
            printErr("error: invalid response from server\n");
            return error.Explained;
        };
        defer accounts_parsed.deinit();

        const accounts_array = blk: {
            if (accounts_parsed.value == .object) {
                if (accounts_parsed.value.object.get("namespaces")) |a| {
                    if (a == .array) break :blk a.array.items;
                }
            }
            printErr("error: unexpected accounts format\n");
            return error.Explained;
        };

        if (accounts_array.len == 0) {
            printErr("error: no accounts found\n");
            return error.Explained;
        }

        // Account + Brain selection loop (Esc on brain goes back to account)
        const selection = try selectAccountAndBrain(allocator, accounts_array, host, api_key);
        if (selection == null) {
            printErr("Aborted.\n");
            return;
        }
        const account_slug = selection.?.account_slug;
        const selected_brain = selection.?.brain_name;
        defer allocator.free(selected_brain);

        // Write .cog.json file
        const cog_content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "brain": {{
            \\    "url": "https://{s}/{s}/{s}"
            \\  }}
            \\}}
            \\
        , .{ host, account_slug, selected_brain });
        defer allocator.free(cog_content);

        const file = std.fs.cwd().createFile(".cog.json", .{}) catch {
            printErr("error: failed to write .cog.json file\n");
            return error.Explained;
        };
        defer file.close();
        var write_buf: [4096]u8 = undefined;
        var fw = file.writer(&write_buf);
        fw.interface.writeAll(cog_content) catch {
            printErr("error: failed to write .cog.json file\n");
            return error.Explained;
        };
        fw.interface.flush() catch {
            printErr("error: failed to write .cog.json file\n");
            return error.Explained;
        };

        printErr("  Wrote .cog.json\n");
    }

    tui.separator();

    // Set up system prompt
    try setupSystemPrompt(allocator, host);
    tui.separator();

    // Install agent skill
    try installSkill(allocator, host);
}

fn buildAccountLabel(allocator: std.mem.Allocator, account: json.Value) ![]const u8 {
    if (account == .object) {
        const name = if (account.object.get("name")) |s| (if (s == .string) s.string else null) else null;
        const acct_type = if (account.object.get("type")) |t| (if (t == .string) t.string else null) else null;
        if (name) |n| {
            if (acct_type) |t| {
                return std.fmt.allocPrint(allocator, "{s} ({s})", .{ n, t });
            }
            return allocator.dupe(u8, n);
        }
    }
    return allocator.dupe(u8, "(unknown)");
}

const AccountBrainSelection = struct {
    account_slug: []const u8,
    brain_name: []const u8,
};

fn selectAccountAndBrain(
    allocator: std.mem.Allocator,
    accounts_array: []const json.Value,
    host: []const u8,
    api_key: []const u8,
) !?AccountBrainSelection {
    // Single account — skip account selection
    if (accounts_array.len == 1) {
        const account = accounts_array[0];
        const slug = getAccountSlug(account) orelse {
            printErr("error: invalid account data\n");
            return error.Explained;
        };
        const brain = try selectBrain(allocator, account, slug, host, api_key);
        if (brain) |b| return .{ .account_slug = slug, .brain_name = b };
        return null; // cancelled
    }

    // Build account menu labels
    var labels: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
    }
    var menu_items: std.ArrayListUnmanaged(tui.MenuItem) = .empty;
    defer menu_items.deinit(allocator);

    for (accounts_array) |account| {
        const label = try buildAccountLabel(allocator, account);
        try labels.append(allocator, label);
        try menu_items.append(allocator, .{ .label = label });
    }

    // Loop: account → brain, Esc on brain returns to account
    while (true) {
        const acct_result = try tui.select(allocator, .{
            .prompt = "Select an account:",
            .items = menu_items.items,
        });
        switch (acct_result) {
            .selected => |idx| {
                const account = accounts_array[idx];
                const slug = getAccountSlug(account) orelse {
                    printErr("error: invalid account data\n");
                    return error.Explained;
                };
                const brain = try selectBrain(allocator, account, slug, host, api_key);
                if (brain) |b| return .{ .account_slug = slug, .brain_name = b };
                // brain returned null (back) — loop to re-show account menu
            },
            .back, .cancelled => return null,
            .input => unreachable,
        }
    }
}

fn getAccountSlug(account: json.Value) ?[]const u8 {
    if (account == .object) {
        if (account.object.get("name")) |s| {
            if (s == .string) return s.string;
        }
    }
    return null;
}

fn selectBrain(
    allocator: std.mem.Allocator,
    selected_account: json.Value,
    account_slug: []const u8,
    host: []const u8,
    api_key: []const u8,
) !?[]const u8 {
    // Extract brains array, or go to create if none
    const brains_items = blk: {
        if (selected_account == .object) {
            if (selected_account.object.get("brains")) |b| {
                if (b == .array and b.array.items.len > 0) break :blk b.array.items;
            }
        }
        // No brains — go straight to create
        printErr("  No brains in ");
        printErr(account_slug);
        printErr(".\n\n");
        return try promptCreateBrain(allocator, account_slug, host, api_key, null);
    };

    var menu_items: std.ArrayListUnmanaged(tui.MenuItem) = .empty;
    defer menu_items.deinit(allocator);

    for (brains_items) |brain| {
        const label = if (brain == .object)
            if (brain.object.get("name")) |n| (if (n == .string) n.string else "?") else "?"
        else
            "?";
        try menu_items.append(allocator, .{ .label = label });
    }
    try menu_items.append(allocator, .{ .label = "Create new brain", .is_input_option = true });

    const prompt_text = try std.fmt.allocPrint(allocator, "Select a brain in {s}:", .{account_slug});
    defer allocator.free(prompt_text);

    const result = try tui.select(allocator, .{
        .prompt = prompt_text,
        .items = menu_items.items,
        .input_validator = &tui.validateBrainName,
    });
    switch (result) {
        .selected => |idx| {
            const brain_val = brains_items[idx];
            if (brain_val == .object) {
                if (brain_val.object.get("name")) |n| {
                    if (n == .string) return try allocator.dupe(u8, n.string);
                }
            }
            printErr("error: invalid brain data\n");
            return error.Explained;
        },
        .input => |name| {
            return try promptCreateBrain(allocator, account_slug, host, api_key, name);
        },
        .back => return null,
        .cancelled => {
            printErr("Aborted.\n");
            return error.Explained;
        },
    }
}

fn promptCreateBrain(
    allocator: std.mem.Allocator,
    account_slug: []const u8,
    host: []const u8,
    api_key: []const u8,
    pre_name: ?[]const u8,
) ![]const u8 {
    const brain_name = if (pre_name) |name|
        name
    else blk: {
        printErr("Brain name: ");
        break :blk try readStdinLine(allocator);
    };
    errdefer allocator.free(brain_name);

    if (brain_name.len == 0) {
        printErr("error: brain name cannot be empty\n");
        return error.Explained;
    }

    printErr("  Creating brain... ");

    var jb = JsonBuilder.init(allocator);
    defer jb.deinit();
    try jb.begin();
    try jb.field("namespace");
    try jb.string(account_slug);
    try jb.field("name");
    try jb.string(brain_name);
    try jb.end();
    const create_args = try jb.toOwnedSlice();
    defer allocator.free(create_args);

    const create_url = try std.fmt.allocPrint(allocator, "https://{s}/api/v1/brains/create", .{host});
    defer allocator.free(create_url);

    const result = client.postRaw(allocator, create_url, api_key, create_args) catch {
        printErr("\n  error: failed to connect to server\n");
        return error.Explained;
    };
    defer allocator.free(result.body);

    if (result.status == .created or result.status == .ok) {
        tui.checkmark();
        printErr("\n\n");
        return brain_name;
    }

    // Check if the error is "already exists" — if so, just use the name
    if (isAlreadyExistsError(allocator, result.body)) {
        tui.checkmark();
        printErr(" (exists)\n\n");
        return brain_name;
    }

    // Some other error
    printErr("\n");
    printServerError(allocator, result.body);
    return error.Explained;
}

fn isAlreadyExistsError(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const err_val = parsed.value.object.get("error") orelse return false;
    if (err_val != .object) return false;
    const msg = err_val.object.get("message") orelse return false;
    if (msg != .string) return false;
    return std.mem.indexOf(u8, msg.string, "has already been taken") != null;
}

fn printServerError(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
        printErr("error: server returned an error\n");
        return;
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |msg| {
                    if (msg == .string) {
                        printErr("error: ");
                        printErr(msg.string);
                        printErr("\n");
                        return;
                    }
                }
            }
        }
    }
    printErr("error: server returned an error\n");
}

// ── System Prompt Setup ─────────────────────────────────────────────────

fn fileExistsInCwd(filename: []const u8) bool {
    const f = std.fs.cwd().openFile(filename, .{}) catch return false;
    f.close();
    return true;
}

fn readCwdFile(allocator: std.mem.Allocator, filename: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(filename, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(allocator, 1048576) catch return null;
}

fn writeCwdFile(filename: []const u8, content: []const u8) !void {
    const file = std.fs.cwd().createFile(filename, .{}) catch {
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
    fw.interface.writeAll(content) catch {
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
    fw.interface.flush() catch {
        printErr("error: failed to write ");
        printErr(filename);
        printErr("\n");
        return error.Explained;
    };
}

fn updateFileWithPrompt(allocator: std.mem.Allocator, filename: []const u8, prompt_content: []const u8) !void {
    const open_tag = "<cog>";
    const close_tag = "</cog>";
    const trimmed_prompt = std.mem.trimRight(u8, prompt_content, &std.ascii.whitespace);

    const existing = readCwdFile(allocator, filename);
    defer if (existing) |e| allocator.free(e);

    const new_content = blk: {
        if (existing) |content| {
            if (std.mem.indexOf(u8, content, open_tag)) |open_pos| {
                const search_start = open_pos + open_tag.len;
                if (std.mem.indexOfPos(u8, content, search_start, close_tag)) |close_pos| {
                    // Replace content between <cog> and </cog>
                    const before = content[0 .. open_pos + open_tag.len];
                    const after = content[close_pos..];
                    break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{ before, trimmed_prompt, after });
                }
            }
            // No valid tags found, append at end
            const trimmed_existing = std.mem.trimRight(u8, content, &std.ascii.whitespace);
            break :blk try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n{s}\n{s}\n", .{ trimmed_existing, open_tag, trimmed_prompt, close_tag });
        } else {
            // New file
            break :blk try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{ open_tag, trimmed_prompt, close_tag });
        }
    };
    defer allocator.free(new_content);

    try writeCwdFile(filename, new_content);
}

fn setupSystemPrompt(allocator: std.mem.Allocator, host: []const u8) !void {
    printErr("  Fetching system prompt... ");
    const prompt_url = try std.fmt.allocPrint(allocator, "https://{s}/PROMPT.md", .{host});
    defer allocator.free(prompt_url);

    const prompt_content = client.httpGetPublic(allocator, prompt_url) catch {
        printErr("\n  error: failed to fetch system prompt\n");
        return error.Explained;
    };
    defer allocator.free(prompt_content);
    tui.checkmark();
    printErr("\n");

    const agents_exists = fileExistsInCwd("AGENTS.md");
    const claude_exists = fileExistsInCwd("CLAUDE.md");

    if (agents_exists and claude_exists) {
        try updateFileWithPrompt(allocator, "AGENTS.md", prompt_content);
        printErr("  Updated AGENTS.md\n");
        try updateFileWithPrompt(allocator, "CLAUDE.md", prompt_content);
        printErr("  Updated CLAUDE.md\n");
    } else if (agents_exists) {
        try updateFileWithPrompt(allocator, "AGENTS.md", prompt_content);
        printErr("  Updated AGENTS.md\n");
    } else if (claude_exists) {
        try updateFileWithPrompt(allocator, "CLAUDE.md", prompt_content);
        printErr("  Updated CLAUDE.md\n");
    } else {
        const file_options = [_]tui.MenuItem{
            .{ .label = "CLAUDE.md" },
            .{ .label = "AGENTS.md" },
        };
        const result = try tui.select(allocator, .{
            .prompt = "Create system prompt in:",
            .items = &file_options,
        });
        switch (result) {
            .selected => |idx| {
                const filename = file_options[idx].label;
                try updateFileWithPrompt(allocator, filename, prompt_content);
                printErr("  Created ");
                printErr(filename);
                printErr("\n");
            },
            .back, .cancelled => {
                printErr("  Skipped system prompt setup.\n");
                return;
            },
            .input => unreachable,
        }
    }
}

// ── Skill Installation ──────────────────────────────────────────────────

fn installSkill(allocator: std.mem.Allocator, host: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse {
        printErr("error: HOME not set\n");
        return error.Explained;
    };

    const skill_options = [_]tui.MenuItem{
        .{ .label = "Claude Code / Copilot / Cursor / Amp / Goose / OpenCode" },
        .{ .label = "Gemini CLI" },
        .{ .label = "OpenAI Codex" },
        .{ .label = "Windsurf" },
        .{ .label = "Roo Code" },
        .{ .label = "Custom path", .is_input_option = true },
    };

    const result = try tui.select(allocator, .{
        .prompt = "Install Cog skill for your agent:",
        .items = &skill_options,
    });

    const base_dir = switch (result) {
        .selected => |idx| switch (idx) {
            0 => try std.fmt.allocPrint(allocator, "{s}/.claude/skills", .{home}),
            1 => try std.fmt.allocPrint(allocator, "{s}/.gemini/skills", .{home}),
            2 => try std.fmt.allocPrint(allocator, "{s}/.agents/skills", .{home}),
            3 => try std.fmt.allocPrint(allocator, "{s}/.codeium/windsurf/skills", .{home}),
            4 => try std.fmt.allocPrint(allocator, "{s}/.roo/skills", .{home}),
            else => unreachable,
        },
        .input => |custom_path| blk: {
            if (custom_path.len == 0) {
                printErr("  Skipped skill installation.\n");
                return;
            }
            // Expand ~ to $HOME
            if (custom_path[0] == '~') {
                break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, custom_path[1..] });
            }
            break :blk try allocator.dupe(u8, custom_path);
        },
        .back, .cancelled => {
            printErr("  Skipped skill installation.\n");
            return;
        },
    };
    defer allocator.free(base_dir);

    // Fetch SKILL.md from server
    printErr("  Fetching skill... ");
    const skill_url = try std.fmt.allocPrint(allocator, "https://{s}/SKILL.md", .{host});
    defer allocator.free(skill_url);

    const skill_content = client.httpGetPublic(allocator, skill_url) catch {
        printErr("\n  error: failed to fetch SKILL.md\n");
        return error.Explained;
    };
    defer allocator.free(skill_content);
    tui.checkmark();
    printErr("\n");

    // Create {base_dir}/cog/ directory (recursive)
    const skill_dir = try std.fmt.allocPrint(allocator, "{s}/cog", .{base_dir});
    defer allocator.free(skill_dir);

    makeDirsAbsolute(skill_dir) catch {
        printErr("  error: failed to create directory ");
        printErr(skill_dir);
        printErr("\n");
        return error.Explained;
    };

    // Write SKILL.md
    const skill_path = try std.fmt.allocPrint(allocator, "{s}/cog/SKILL.md", .{base_dir});
    defer allocator.free(skill_path);

    writeAbsoluteFile(skill_path, skill_content) catch {
        return error.Explained;
    };

    printErr("  Installed ");
    printErr(skill_path);
    printErr("\n");
}

fn makeDirsAbsolute(path: []const u8) !void {
    // Strip leading '/' to get a relative path from root
    const rel_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();
    try root.makePath(rel_path);
}

fn writeAbsoluteFile(path: []const u8, content: []const u8) !void {
    const file = std.fs.createFileAbsolute(path, .{}) catch {
        printErr("error: failed to write ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
    fw.interface.writeAll(content) catch {
        printErr("error: failed to write ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
    fw.interface.flush() catch {
        printErr("error: failed to write ");
        printErr(path);
        printErr("\n");
        return error.Explained;
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parseCompoundValue basic" {
    var kvs: [4]KV = undefined;
    const count = parseCompoundValue("target:foo,predicate:bar", &kvs);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("target", kvs[0].key);
    try std.testing.expectEqualStrings("foo", kvs[0].value);
    try std.testing.expectEqualStrings("predicate", kvs[1].key);
    try std.testing.expectEqualStrings("bar", kvs[1].value);
}

test "parseCompoundValue single" {
    var kvs: [4]KV = undefined;
    const count = parseCompoundValue("term:hello world", &kvs);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("term", kvs[0].key);
    try std.testing.expectEqualStrings("hello world", kvs[0].value);
}
