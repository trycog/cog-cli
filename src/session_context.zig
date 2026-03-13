const std = @import("std");
const json = std.json;
const debug_log = @import("debug_log.zig");
const repo_context_mod = @import("repo_context.zig");

pub const SourceChannel = enum {
    user_instruction,
    code_exploration,
    debug_session,
    task_synthesis,
    manual_memory_write,
    bootstrap,
};

pub const WriteReasonHint = enum {
    architecture_rule,
    rationale,
    workflow_constraint,
    bug_pattern,
    implementation_detail,
    generic,
};

pub const ContextEventKind = enum {
    code_explore,
    code_query,
    debug_launch,
    debug_evidence,
    debug_stop,
    memory_recall,
    memory_write,
    question,
    task_delegate,
    resource_read,
    prompt_get,
};

pub const ContextEvent = struct {
    kind: ContextEventKind,
    timestamp: i64,
    tool_name: []const u8,
    summary: []const u8,
    metadata: []const u8,

    fn deinit(self: *ContextEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.summary);
        allocator.free(self.metadata);
    }
};

pub const WriteContext = struct {
    source_channel: SourceChannel,
    source_details: []const u8,
    recent_symbols: []const []const u8,
    recent_files: []const []const u8,
    recent_debug_targets: []const []const u8,
    recent_tool_sequence: []const []const u8,
    write_reason_hint: WriteReasonHint,
    user_provided_fact_recently: bool,

    pub fn deinit(self: *WriteContext, allocator: std.mem.Allocator) void {
        allocator.free(self.source_details);
        freeStringSlice(allocator, self.recent_symbols);
        freeStringSlice(allocator, self.recent_files);
        freeStringSlice(allocator, self.recent_debug_targets);
        freeStringSlice(allocator, self.recent_tool_sequence);
    }
};

pub const SessionContext = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8,
    host_agent_id: []const u8,
    workspace_root: []const u8,
    brain_url: []const u8,
    brain_namespace: ?[]const u8,
    brain_name: ?[]const u8,
    cwd: []const u8,
    repo_root: ?[]const u8,
    repo_remote_origin: ?[]const u8,
    repo_head_sha: ?[]const u8,
    started_at: i64,
    last_tool_at: i64,
    tool_history_ring: std.ArrayListUnmanaged(ContextEvent) = .empty,
    memory_write_count: usize = 0,
    code_query_count: usize = 0,
    debug_activity_count: usize = 0,
    recent_code_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    recent_debug_targets: std.ArrayListUnmanaged([]const u8) = .empty,
    recent_user_fact_markers: std.ArrayListUnmanaged(i64) = .empty,
    recent_user_facts_pending: bool = false,
    awaiting_user_answer: bool = false,

    pub fn deinit(self: *SessionContext) void {
        const allocator = self.allocator;
        allocator.free(self.session_id);
        allocator.free(self.host_agent_id);
        allocator.free(self.workspace_root);
        allocator.free(self.brain_url);
        if (self.brain_namespace) |value| allocator.free(value);
        if (self.brain_name) |value| allocator.free(value);
        allocator.free(self.cwd);
        if (self.repo_root) |value| allocator.free(value);
        if (self.repo_remote_origin) |value| allocator.free(value);
        if (self.repo_head_sha) |value| allocator.free(value);
        for (self.tool_history_ring.items) |*event| event.deinit(allocator);
        self.tool_history_ring.deinit(allocator);
        freeOwnedList(allocator, &self.recent_code_targets);
        freeOwnedList(allocator, &self.recent_debug_targets);
        self.recent_user_fact_markers.deinit(allocator);
    }
};

pub fn initSessionContext(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    host_agent_id: []const u8,
    workspace_root: []const u8,
    brain_url: []const u8,
    brain_namespace: ?[]const u8,
    brain_name: ?[]const u8,
    repo_context: *const repo_context_mod.RepoContext,
) !SessionContext {
    const now = std.time.timestamp();
    debug_log.log("session_context.init: session={s} host={s} workspace={s}", .{ session_id, host_agent_id, workspace_root });
    return .{
        .allocator = allocator,
        .session_id = try allocator.dupe(u8, session_id),
        .host_agent_id = try allocator.dupe(u8, host_agent_id),
        .workspace_root = try allocator.dupe(u8, workspace_root),
        .brain_url = try allocator.dupe(u8, brain_url),
        .brain_namespace = if (brain_namespace) |value| try allocator.dupe(u8, value) else null,
        .brain_name = if (brain_name) |value| try allocator.dupe(u8, value) else null,
        .cwd = try allocator.dupe(u8, repo_context.cwd),
        .repo_root = if (repo_context.repo_root) |value| try allocator.dupe(u8, value) else null,
        .repo_remote_origin = if (repo_context.repo_remote_origin) |value| try allocator.dupe(u8, value) else null,
        .repo_head_sha = if (repo_context.repo_head_sha) |value| try allocator.dupe(u8, value) else null,
        .started_at = now,
        .last_tool_at = now,
    };
}

pub fn recordToolEvent(ctx: *SessionContext, tool_name: []const u8, arguments: ?json.Value) !void {
    const kind = classifyToolEvent(tool_name);
    const now = std.time.timestamp();
    const summary = try buildEventSummary(ctx.allocator, tool_name, arguments);
    errdefer ctx.allocator.free(summary);
    const metadata = try buildEventMetadata(ctx.allocator, arguments);
    errdefer ctx.allocator.free(metadata);

    try appendEvent(&ctx.tool_history_ring, ctx.allocator, .{
        .kind = kind,
        .timestamp = now,
        .tool_name = try ctx.allocator.dupe(u8, tool_name),
        .summary = summary,
        .metadata = metadata,
    }, 20);

    ctx.last_tool_at = now;

    if (ctx.awaiting_user_answer and kind != .question) {
        ctx.awaiting_user_answer = false;
        ctx.recent_user_facts_pending = true;
        try appendTimestamp(&ctx.recent_user_fact_markers, ctx.allocator, now, 5);
        debug_log.log("session_context.recordToolEvent: inferred user answer before tool={s}", .{tool_name});
    }

    switch (kind) {
        .code_explore, .code_query => ctx.code_query_count += 1,
        .debug_launch, .debug_evidence, .debug_stop => ctx.debug_activity_count += 1,
        .memory_write => {
            ctx.memory_write_count += 1;
            ctx.recent_user_facts_pending = false;
            ctx.recent_user_fact_markers.clearRetainingCapacity();
        },
        .question => ctx.awaiting_user_answer = true,
        else => {},
    }

    switch (kind) {
        .code_explore, .code_query => try updateCodeTargets(ctx, arguments),
        .debug_launch, .debug_evidence => try updateDebugTargets(ctx, arguments),
        else => {},
    }

    debug_log.log("session_context.recordToolEvent: session={s} tool={s} kind={s}", .{ ctx.session_id, tool_name, @tagName(kind) });
}

pub fn recordUserFactMarker(ctx: *SessionContext) void {
    ctx.recent_user_facts_pending = true;
    appendTimestamp(&ctx.recent_user_fact_markers, ctx.allocator, std.time.timestamp(), 5) catch {};
    debug_log.log("session_context.recordUserFactMarker: session={s}", .{ctx.session_id});
}

pub fn buildWriteContext(
    allocator: std.mem.Allocator,
    ctx: *const SessionContext,
    tool_name: []const u8,
    arguments: ?json.Value,
) !WriteContext {
    const source_channel = classifyWriteSource(ctx, tool_name, arguments);
    const source_details = try buildSourceDetails(allocator, ctx, source_channel);
    errdefer allocator.free(source_details);
    const recent_symbols = try dupeStringSlice(allocator, ctx.recent_code_targets.items);
    errdefer freeStringSlice(allocator, recent_symbols);
    const recent_files = try collectRecentFiles(allocator, ctx);
    errdefer freeStringSlice(allocator, recent_files);
    const recent_debug_targets = try dupeStringSlice(allocator, ctx.recent_debug_targets.items);
    errdefer freeStringSlice(allocator, recent_debug_targets);
    const recent_tool_sequence = try collectRecentToolSequence(allocator, ctx);
    errdefer freeStringSlice(allocator, recent_tool_sequence);

    const write_reason_hint = classifyWriteReasonHint(tool_name, arguments);
    debug_log.log(
        "session_context.buildWriteContext: session={s} source={s} reason={s}",
        .{ ctx.session_id, @tagName(source_channel), @tagName(write_reason_hint) },
    );

    return .{
        .source_channel = source_channel,
        .source_details = source_details,
        .recent_symbols = recent_symbols,
        .recent_files = recent_files,
        .recent_debug_targets = recent_debug_targets,
        .recent_tool_sequence = recent_tool_sequence,
        .write_reason_hint = write_reason_hint,
        .user_provided_fact_recently = ctx.recent_user_facts_pending,
    };
}

pub fn classifyWriteSource(ctx: *const SessionContext, tool_name: []const u8, arguments: ?json.Value) SourceChannel {
    _ = arguments;

    if (std.mem.eql(u8, tool_name, "mem_learn")) {
        const last_event = if (ctx.tool_history_ring.items.len > 0) ctx.tool_history_ring.items[ctx.tool_history_ring.items.len - 1] else null;
        if (last_event != null and std.mem.indexOf(u8, last_event.?.summary, "bootstrap") != null) {
            return .bootstrap;
        }
    }

    if (std.mem.eql(u8, tool_name, "mem_reinforce") or std.mem.eql(u8, tool_name, "mem_flush")) {
        return .task_synthesis;
    }

    var index = ctx.tool_history_ring.items.len;
    var saw_code = false;
    while (index > 0) {
        index -= 1;
        const event = ctx.tool_history_ring.items[index];
        switch (event.kind) {
            .debug_launch, .debug_evidence, .debug_stop => return .debug_session,
            .code_explore, .code_query => saw_code = true,
            else => {},
        }
    }

    if (saw_code) return .code_exploration;
    if (ctx.recent_user_fact_markers.items.len > 0 or ctx.recent_user_facts_pending) return .user_instruction;
    return .manual_memory_write;
}

fn classifyToolEvent(tool_name: []const u8) ContextEventKind {
    if (std.mem.eql(u8, tool_name, "code_explore")) return .code_explore;
    if (std.mem.eql(u8, tool_name, "code_query")) return .code_query;
    if (std.mem.eql(u8, tool_name, "debug_launch") or std.mem.eql(u8, tool_name, "debug_attach")) return .debug_launch;
    if (std.mem.eql(u8, tool_name, "debug_stop")) return .debug_stop;
    if (std.mem.startsWith(u8, tool_name, "debug_")) return .debug_evidence;
    if (std.mem.eql(u8, tool_name, "mem_recall") or std.mem.eql(u8, tool_name, "mem_bulk_recall") or std.mem.eql(u8, tool_name, "mem_trace") or std.mem.eql(u8, tool_name, "mem_connections") or std.mem.eql(u8, tool_name, "mem_get") or std.mem.eql(u8, tool_name, "mem_list_short_term") or std.mem.eql(u8, tool_name, "mem_stats") or std.mem.eql(u8, tool_name, "mem_orphans") or std.mem.eql(u8, tool_name, "mem_connectivity") or std.mem.eql(u8, tool_name, "mem_list_terms") or std.mem.eql(u8, tool_name, "mem_stale")) return .memory_recall;
    if (std.mem.startsWith(u8, tool_name, "mem_")) return .memory_write;
    if (std.mem.eql(u8, tool_name, "question")) return .question;
    if (std.mem.eql(u8, tool_name, "task")) return .task_delegate;
    if (std.mem.eql(u8, tool_name, "read") or std.mem.eql(u8, tool_name, "list")) return .resource_read;
    return .prompt_get;
}

fn buildEventSummary(allocator: std.mem.Allocator, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    if (arguments) |args| {
        if (std.mem.eql(u8, tool_name, "code_explore")) {
            if (args == .object) {
                if (args.object.get("queries")) |queries| {
                    const names = try collectQueryNames(allocator, queries);
                    defer freeStringSlice(allocator, names);
                    return joinOrDefault(allocator, names, "queryless-code-explore");
                }
            }
        }

        if (std.mem.eql(u8, tool_name, "code_query")) {
            if (getString(args, "name")) |name| return allocator.dupe(u8, name);
            if (getString(args, "file")) |file| return allocator.dupe(u8, file);
        }

        if (std.mem.startsWith(u8, tool_name, "debug_")) {
            if (getString(args, "program")) |program| return allocator.dupe(u8, program);
            if (getString(args, "module")) |module| return allocator.dupe(u8, module);
            if (getString(args, "expression")) |expression| return allocator.dupe(u8, expression);
            if (getString(args, "file")) |file| return allocator.dupe(u8, file);
        }

        if (std.mem.startsWith(u8, tool_name, "mem_")) {
            if (getString(args, "term")) |term| return allocator.dupe(u8, term);
            if (getString(args, "source_term")) |source_term| return allocator.dupe(u8, source_term);
            if (getString(args, "engram_id")) |engram_id| return allocator.dupe(u8, engram_id);
            if (getString(args, "query")) |query| return allocator.dupe(u8, query);
        }
    }

    return allocator.dupe(u8, tool_name);
}

fn buildEventMetadata(allocator: std.mem.Allocator, arguments: ?json.Value) ![]const u8 {
    if (arguments) |args| {
        return @import("client.zig").writeJsonValue(allocator, args);
    }
    return allocator.dupe(u8, "{}");
}

fn updateCodeTargets(ctx: *SessionContext, arguments: ?json.Value) !void {
    const allocator = ctx.allocator;
    if (arguments) |args| {
        if (args == .object) {
            if (args.object.get("queries")) |queries| {
                const names = try collectQueryNames(allocator, queries);
                defer freeStringSlice(allocator, names);
                for (names) |name| try appendOwnedString(&ctx.recent_code_targets, allocator, name, 8);
            }
        }

        if (getString(args, "name")) |name| {
            try appendOwnedString(&ctx.recent_code_targets, allocator, name, 8);
        }
        if (getString(args, "file")) |file| {
            try appendOwnedString(&ctx.recent_code_targets, allocator, file, 8);
        }
    }
}

fn updateDebugTargets(ctx: *SessionContext, arguments: ?json.Value) !void {
    const allocator = ctx.allocator;
    if (arguments) |args| {
        if (getString(args, "program")) |program| {
            try appendOwnedString(&ctx.recent_debug_targets, allocator, program, 5);
        } else if (getString(args, "module")) |module| {
            try appendOwnedString(&ctx.recent_debug_targets, allocator, module, 5);
        } else if (getString(args, "file")) |file| {
            try appendOwnedString(&ctx.recent_debug_targets, allocator, file, 5);
        } else if (getString(args, "expression")) |expression| {
            try appendOwnedString(&ctx.recent_debug_targets, allocator, expression, 5);
        }
    }
}

fn buildSourceDetails(allocator: std.mem.Allocator, ctx: *const SessionContext, source_channel: SourceChannel) ![]const u8 {
    if (ctx.tool_history_ring.items.len == 0) {
        return std.fmt.allocPrint(allocator, "source={s}; no prior tool evidence", .{@tagName(source_channel)});
    }

    const event = ctx.tool_history_ring.items[ctx.tool_history_ring.items.len - 1];
    return std.fmt.allocPrint(allocator, "source={s}; recent_tool={s}; summary={s}", .{ @tagName(source_channel), event.tool_name, event.summary });
}

fn classifyWriteReasonHint(tool_name: []const u8, arguments: ?json.Value) WriteReasonHint {
    if (std.mem.eql(u8, tool_name, "mem_deprecate")) return .workflow_constraint;
    if (std.mem.eql(u8, tool_name, "mem_refactor") or std.mem.eql(u8, tool_name, "mem_update")) return .implementation_detail;

    const text = extractReasonText(arguments) orelse return .generic;
    if (containsAny(text, &.{ "because", "why", "so that", "in order", "reason" })) return .rationale;
    if (containsAny(text, &.{ "constraint", "invariant", "must", "never", "always" })) return .workflow_constraint;
    if (containsAny(text, &.{ "bug", "race", "crash", "failure", "regression" })) return .bug_pattern;
    if (containsAny(text, &.{ "architecture", "layer", "pipeline", "compiler", "integration", "design" })) return .architecture_rule;
    if (containsAny(text, &.{ "implementation", "details", "field", "function", "module", "struct" })) return .implementation_detail;
    return .generic;
}

fn extractReasonText(arguments: ?json.Value) ?[]const u8 {
    const args = arguments orelse return null;
    if (getString(args, "definition")) |definition| return definition;
    if (getString(args, "query")) |query| return query;
    if (args == .object) {
        if (args.object.get("items")) |items| {
            if (items == .array and items.array.items.len > 0) {
                if (items.array.items[0] == .object) {
                    if (items.array.items[0].object.get("definition")) |definition| {
                        if (definition == .string) return definition.string;
                    }
                }
            }
        }
    }
    return null;
}

fn collectQueryNames(allocator: std.mem.Allocator, queries: json.Value) ![]const []const u8 {
    if (queries != .array) return allocator.alloc([]const u8, 0);

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &list);
    for (queries.array.items) |query| {
        if (query != .object) continue;
        if (query.object.get("name")) |name| {
            if (name == .string) try list.append(allocator, try allocator.dupe(u8, name.string));
        }
    }
    return list.toOwnedSlice(allocator);
}

fn collectRecentFiles(allocator: std.mem.Allocator, ctx: *const SessionContext) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeOwnedList(allocator, &list);

    for (ctx.tool_history_ring.items) |event| {
        if (event.kind != .code_query and event.kind != .code_explore and event.kind != .debug_launch and event.kind != .debug_evidence) continue;
        if (std.mem.indexOf(u8, event.summary, "/") == null and std.mem.indexOf(u8, event.summary, ".zig") == null) continue;
        if (containsString(list.items, event.summary)) continue;
        try list.append(allocator, try allocator.dupe(u8, event.summary));
    }

    return list.toOwnedSlice(allocator);
}

fn collectRecentToolSequence(allocator: std.mem.Allocator, ctx: *const SessionContext) ![]const []const u8 {
    const limit: usize = 6;
    const history = ctx.tool_history_ring.items;
    const start = if (history.len > limit) history.len - limit else 0;
    var list = try allocator.alloc([]const u8, history.len - start);
    errdefer allocator.free(list);
    for (history[start..], 0..) |event, index| {
        list[index] = try allocator.dupe(u8, event.tool_name);
    }
    return list;
}

fn joinOrDefault(allocator: std.mem.Allocator, strings: []const []const u8, fallback: []const u8) ![]const u8 {
    if (strings.len == 0) return allocator.dupe(u8, fallback);
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);
    for (strings, 0..) |value, index| {
        if (index > 0) try list.appendSlice(allocator, ",");
        try list.appendSlice(allocator, value);
    }
    return list.toOwnedSlice(allocator);
}

fn appendEvent(list: *std.ArrayListUnmanaged(ContextEvent), allocator: std.mem.Allocator, event: ContextEvent, max_items: usize) !void {
    if (list.items.len >= max_items) {
        list.items[0].deinit(allocator);
        var index: usize = 1;
        while (index < list.items.len) : (index += 1) {
            list.items[index - 1] = list.items[index];
        }
        list.items.len -= 1;
    }
    try list.append(allocator, event);
}

fn appendOwnedString(list: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator, value: []const u8, max_items: usize) !void {
    if (containsString(list.items, value)) return;
    if (list.items.len >= max_items) {
        allocator.free(list.items[0]);
        var index: usize = 1;
        while (index < list.items.len) : (index += 1) {
            list.items[index - 1] = list.items[index];
        }
        list.items.len -= 1;
    }
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn appendTimestamp(list: *std.ArrayListUnmanaged(i64), allocator: std.mem.Allocator, value: i64, max_items: usize) !void {
    if (list.items.len >= max_items) {
        var index: usize = 1;
        while (index < list.items.len) : (index += 1) {
            list.items[index - 1] = list.items[index];
        }
        list.items.len -= 1;
    }
    try list.append(allocator, value);
}

fn containsString(strings: []const []const u8, needle: []const u8) bool {
    for (strings) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

fn getString(value: json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(field) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn freeOwnedList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn freeStringSlice(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |value| allocator.free(value);
    allocator.free(strings);
}

fn dupeStringSlice(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(copy);
    for (strings, 0..) |value, index| {
        copy[index] = try allocator.dupe(u8, value);
    }
    return copy;
}

test "classifyWriteSource prefers debug over code exploration" {
    var repo_context = repo_context_mod.RepoContext{
        .cwd = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_root = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_remote_origin = null,
        .repo_head_sha = null,
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(std.testing.allocator);

    var ctx = try initSessionContext(std.testing.allocator, "session-1", "opencode", "/tmp/project", "https://trycog.ai/acme/brain", "acme", "brain", &repo_context);
    defer ctx.deinit();

    const code_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"name\":\"Runtime\"}", .{});
    defer code_args.deinit();
    try recordToolEvent(&ctx, "code_query", code_args.value);

    const debug_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"program\":\"zig test\"}", .{});
    defer debug_args.deinit();
    try recordToolEvent(&ctx, "debug_launch", debug_args.value);

    try std.testing.expectEqual(SourceChannel.debug_session, classifyWriteSource(&ctx, "mem_learn", null));
}

test "buildWriteContext includes recent tool sequence and targets" {
    var repo_context = repo_context_mod.RepoContext{
        .cwd = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_root = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_remote_origin = try std.testing.allocator.dupe(u8, "git@github.com:trycog/cog-cli.git"),
        .repo_head_sha = try std.testing.allocator.dupe(u8, "abc123"),
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(std.testing.allocator);

    var ctx = try initSessionContext(std.testing.allocator, "session-2", "opencode", "/tmp/project", "https://trycog.ai/acme/brain", "acme", "brain", &repo_context);
    defer ctx.deinit();

    const explore_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"queries\":[{\"name\":\"Runtime\"},{\"name\":\"discoverRemoteTools\"}]}", .{});
    defer explore_args.deinit();
    try recordToolEvent(&ctx, "code_explore", explore_args.value);

    const debug_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"file\":\"src/mcp.zig\"}", .{});
    defer debug_args.deinit();
    try recordToolEvent(&ctx, "debug_inspect", debug_args.value);

    const write_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"definition\":\"because the client compiles provenance at write time\"}", .{});
    defer write_args.deinit();

    var write_context = try buildWriteContext(std.testing.allocator, &ctx, "mem_learn", write_args.value);
    defer write_context.deinit(std.testing.allocator);

    try std.testing.expectEqual(SourceChannel.debug_session, write_context.source_channel);
    try std.testing.expectEqual(WriteReasonHint.rationale, write_context.write_reason_hint);
    try std.testing.expect(write_context.recent_symbols.len >= 2);
    try std.testing.expect(write_context.recent_debug_targets.len >= 1);
    try std.testing.expect(write_context.recent_tool_sequence.len >= 2);
}

test "recordUserFactMarker makes user instructions win when no code evidence exists" {
    var repo_context = repo_context_mod.RepoContext{
        .cwd = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_root = null,
        .repo_remote_origin = null,
        .repo_head_sha = null,
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(std.testing.allocator);

    var ctx = try initSessionContext(std.testing.allocator, "session-3", "cursor", "/tmp/project", "https://trycog.ai/acme/brain", "acme", "brain", &repo_context);
    defer ctx.deinit();
    recordUserFactMarker(&ctx);

    try std.testing.expectEqual(SourceChannel.user_instruction, classifyWriteSource(&ctx, "mem_learn", null));
}

test "question followed by tool infers recent user fact marker" {
    var repo_context = repo_context_mod.RepoContext{
        .cwd = try std.testing.allocator.dupe(u8, "/tmp/project"),
        .repo_root = null,
        .repo_remote_origin = null,
        .repo_head_sha = null,
        .repo_fingerprint = null,
    };
    defer repo_context.deinit(std.testing.allocator);

    var ctx = try initSessionContext(std.testing.allocator, "session-4", "claude_code", "/tmp/project", "https://trycog.ai/acme/brain", "acme", "brain", &repo_context);
    defer ctx.deinit();

    try recordToolEvent(&ctx, "question", null);
    const next_args = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"file\":\"src/mcp.zig\"}", .{});
    defer next_args.deinit();
    try recordToolEvent(&ctx, "read", next_args.value);

    try std.testing.expect(ctx.recent_user_facts_pending);
    try std.testing.expectEqual(@as(usize, 1), ctx.recent_user_fact_markers.items.len);
    try std.testing.expectEqual(SourceChannel.user_instruction, classifyWriteSource(&ctx, "mem_learn", null));
}
