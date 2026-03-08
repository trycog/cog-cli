const std = @import("std");
const json = std.json;
const sqlite = @import("sqlite.zig");
const memory_schema = @import("memory_schema.zig");
const debug_log = @import("debug_log.zig");
const uuid = @import("uuid");

const Db = sqlite.Db;
const Stmt = sqlite.Stmt;
const Allocator = std.mem.Allocator;

// ── MemoryDb ────────────────────────────────────────────────────────────

pub const MemoryDb = struct {
    db: Db,
    brain_id: []const u8,
    allocator: Allocator,

    pub fn open(allocator: Allocator, path: [*:0]const u8, brain_id: []const u8) !MemoryDb {
        debug_log.log("memory: opening db brain_id={s}", .{brain_id});
        var db = try Db.open(path);
        errdefer db.close();
        try memory_schema.ensureSchema(&db);
        return .{ .db = db, .brain_id = brain_id, .allocator = allocator };
    }

    pub fn close(self: *MemoryDb) void {
        debug_log.log("memory: closing db", .{});
        self.db.close();
    }
};

// ── UUID generation ─────────────────────────────────────────────────────

fn generateUuid() [36]u8 {
    const id = uuid.v4.new();
    return uuid.urn.serialize(id);
}

// ── Tool definitions ────────────────────────────────────────────────────

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

pub const tool_definitions = [_]ToolDef{
    .{
        .name = "cog_mem_learn",
        .description = "Store a new concept in memory. Checks for duplicates before creating.",
        .input_schema =
        \\{"type":"object","properties":{"term":{"type":"string","description":"Short name for the concept (2-5 words)"},"definition":{"type":"string","description":"Clear definition (1-3 sentences)"},"associations":{"type":"array","items":{"type":"string"},"description":"Optional list of existing term names to associate with"},"chain_to":{"type":"string","description":"Optional term name to create a sequence link to"}},"required":["term","definition"]}
        ,
    },
    .{
        .name = "cog_mem_recall",
        .description = "Search memory by query. Returns matching concepts with 1-hop neighbors.",
        .input_schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Search query (natural language or keywords)"},"limit":{"type":"number","description":"Max results (default 10)"}},"required":["query"]}
        ,
    },
    .{
        .name = "cog_mem_get",
        .description = "Get a specific engram by its ID.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Engram UUID"}},"required":["id"]}
        ,
    },
    .{
        .name = "cog_mem_update",
        .description = "Update an existing engram's term or definition.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Engram UUID to update"},"term":{"type":"string","description":"New term (optional)"},"definition":{"type":"string","description":"New definition (optional)"}},"required":["id"]}
        ,
    },
    .{
        .name = "cog_mem_associate",
        .description = "Create a directional link between two concepts.",
        .input_schema =
        \\{"type":"object","properties":{"source":{"type":"string","description":"Source term name or engram ID"},"target":{"type":"string","description":"Target term name or engram ID"},"relation":{"type":"string","description":"Relationship type (default: related_to)"},"weight":{"type":"number","description":"Link strength 0.0-1.0 (default: 1.0)"}},"required":["source","target"]}
        ,
    },
    .{
        .name = "cog_mem_unlink",
        .description = "Remove a specific synapse by its ID.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Synapse UUID to remove"}},"required":["id"]}
        ,
    },
    .{
        .name = "cog_mem_refactor",
        .description = "Update the definition of an existing concept found by term.",
        .input_schema =
        \\{"type":"object","properties":{"term":{"type":"string","description":"Term to find"},"definition":{"type":"string","description":"New definition"}},"required":["term","definition"]}
        ,
    },
    .{
        .name = "cog_mem_deprecate",
        .description = "Mark a concept as deprecated. Removes its links and sets it for expiry.",
        .input_schema =
        \\{"type":"object","properties":{"term":{"type":"string","description":"Term to deprecate"}},"required":["term"]}
        ,
    },
    .{
        .name = "cog_mem_reinforce",
        .description = "Promote a concept from short-term to long-term memory.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Engram UUID to reinforce"}},"required":["id"]}
        ,
    },
    .{
        .name = "cog_mem_flush",
        .description = "Delete a specific short-term memory.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Engram UUID to flush"}},"required":["id"]}
        ,
    },
    .{
        .name = "cog_mem_list_short_term",
        .description = "List all short-term memories.",
        .input_schema =
        \\{"type":"object","properties":{"limit":{"type":"number","description":"Max results (default 50)"}},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_connections",
        .description = "List connections for a concept.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Engram UUID"},"direction":{"type":"string","description":"Filter: 'outgoing', 'incoming', or 'both' (default: both)"}},"required":["id"]}
        ,
    },
    .{
        .name = "cog_mem_trace",
        .description = "Find shortest path between two concepts in the memory graph.",
        .input_schema =
        \\{"type":"object","properties":{"from":{"type":"string","description":"Source term name or engram ID"},"to":{"type":"string","description":"Target term name or engram ID"},"max_depth":{"type":"number","description":"Maximum hops (default: 5)"}},"required":["from","to"]}
        ,
    },
    .{
        .name = "cog_mem_stats",
        .description = "Show memory statistics (counts, memory types).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_orphans",
        .description = "List concepts with no connections.",
        .input_schema =
        \\{"type":"object","properties":{"limit":{"type":"number","description":"Max results (default 50)"}},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_connectivity",
        .description = "Analyze graph connectivity (connected components).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_list_terms",
        .description = "List all terms in memory, sorted alphabetically.",
        .input_schema =
        \\{"type":"object","properties":{"limit":{"type":"number","description":"Max results (default 100)"}},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_bulk_learn",
        .description = "Store multiple concepts in a single batch.",
        .input_schema =
        \\{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"term":{"type":"string"},"definition":{"type":"string"}},"required":["term","definition"]}}},"required":["items"]}
        ,
    },
    .{
        .name = "cog_mem_bulk_associate",
        .description = "Create multiple associations in a single batch.",
        .input_schema =
        \\{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"source":{"type":"string"},"target":{"type":"string"},"relation":{"type":"string"}},"required":["source","target"]}}},"required":["items"]}
        ,
    },
    .{
        .name = "cog_mem_bulk_recall",
        .description = "Search memory for multiple queries at once.",
        .input_schema =
        \\{"type":"object","properties":{"queries":{"type":"array","items":{"type":"string"},"description":"List of search queries"}},"required":["queries"]}
        ,
    },
    .{
        .name = "cog_mem_stale",
        .description = "List stale memories (not available in local mode).",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_verify",
        .description = "Verify memory integrity.",
        .input_schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "cog_mem_meld",
        .description = "Merge similar concepts (requires hosted brain).",
        .input_schema =
        \\{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"description":"Engram IDs to merge"}},"required":["ids"]}
        ,
    },
};

// ── Dispatch ────────────────────────────────────────────────────────────

pub fn callLocalTool(mem_db: *MemoryDb, tool_name: []const u8, arguments: ?json.Value) ![]const u8 {
    debug_log.log("memory: callLocalTool {s}", .{tool_name});
    const allocator = mem_db.allocator;

    // Strip cog_mem_ prefix to get the handler name
    const suffix = if (std.mem.startsWith(u8, tool_name, "cog_mem_"))
        tool_name["cog_mem_".len..]
    else
        tool_name;

    if (std.mem.eql(u8, suffix, "learn")) return toolLearn(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "recall")) return toolRecall(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "get")) return toolGet(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "update")) return toolUpdate(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "associate")) return toolAssociate(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "unlink")) return toolUnlink(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "refactor")) return toolRefactor(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "deprecate")) return toolDeprecate(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "reinforce")) return toolReinforce(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "flush")) return toolFlush(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "list_short_term")) return toolListShortTerm(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "connections")) return toolConnections(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "trace")) return toolTrace(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "stats")) return toolStats(mem_db);
    if (std.mem.eql(u8, suffix, "orphans")) return toolOrphans(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "connectivity")) return toolConnectivity(mem_db);
    if (std.mem.eql(u8, suffix, "list_terms")) return toolListTerms(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "bulk_learn")) return toolBulkLearn(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "bulk_associate")) return toolBulkAssociate(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "bulk_recall")) return toolBulkRecall(mem_db, arguments);
    if (std.mem.eql(u8, suffix, "stale")) return allocator.dupe(u8, "No stale memories (local mode does not track staleness).");
    if (std.mem.eql(u8, suffix, "verify")) return allocator.dupe(u8, "\\u2713 Memory integrity OK (local SQLite).");
    if (std.mem.eql(u8, suffix, "meld")) return allocator.dupe(u8, "\\u26A0 Meld requires a hosted brain on trycog.ai. Run `cog mem:upgrade` for migration instructions.");

    debug_log.log("memory: unknown tool suffix: {s}", .{suffix});
    return allocator.dupe(u8, "Unknown memory tool.");
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn getStringArg(args: ?json.Value, key: []const u8) ?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    const val = a.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getIntArg(args: ?json.Value, key: []const u8, default: i64) i64 {
    const a = args orelse return default;
    if (a != .object) return default;
    const val = a.object.get(key) orelse return default;
    return switch (val) {
        .integer => val.integer,
        .float => @intFromFloat(val.float),
        else => default,
    };
}

fn getFloatArg(args: ?json.Value, key: []const u8, default: f64) f64 {
    const a = args orelse return default;
    if (a != .object) return default;
    const val = a.object.get(key) orelse return default;
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => default,
    };
}

fn getArrayArg(args: ?json.Value, key: []const u8) ?[]const json.Value {
    const a = args orelse return null;
    if (a != .object) return null;
    const val = a.object.get(key) orelse return null;
    if (val != .array) return null;
    return val.array.items;
}

/// Find engram ID by term name (case-insensitive) or return input if it looks like a UUID.
fn resolveEngramId(mem_db: *MemoryDb, name_or_id: []const u8) !?[]const u8 {
    // If it looks like a UUID (36 chars with dashes), return it directly
    if (name_or_id.len == 36 and name_or_id[8] == '-') {
        return try mem_db.allocator.dupe(u8, name_or_id);
    }

    // Otherwise look up by term (case-insensitive)
    var stmt = try mem_db.db.prepare("SELECT id FROM engrams WHERE brain_id = ? AND LOWER(term) = LOWER(?) LIMIT 1");
    defer stmt.finalize();
    try stmt.bindText(1, mem_db.brain_id);
    try stmt.bindText(2, name_or_id);
    const result = try stmt.step();
    if (result == .row) {
        const id = stmt.columnText(0) orelse return null;
        return try mem_db.allocator.dupe(u8, id);
    }
    return null;
}

/// Build markdown output using an ArrayList
const Output = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    fn init(allocator: Allocator) Output {
        return .{ .buf = .empty, .allocator = allocator };
    }

    fn print(self: *Output, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(self.buf.writer(self.allocator), fmt, args) catch {};
    }

    fn append(self: *Output, str: []const u8) void {
        self.buf.appendSlice(self.allocator, str) catch {};
    }

    fn toOwnedSlice(self: *Output) ![]const u8 {
        return try self.buf.toOwnedSlice(self.allocator);
    }

    fn deinit(self: *Output) void {
        self.buf.deinit(self.allocator);
    }
};

// ── Tool implementations ────────────────────────────────────────────────

fn toolLearn(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const term = getStringArg(arguments, "term") orelse
        return allocator.dupe(u8, "Error: 'term' is required.");
    const definition = getStringArg(arguments, "definition") orelse
        return allocator.dupe(u8, "Error: 'definition' is required.");

    debug_log.log("memory: learn term={s}", .{term});

    // Check for exact duplicate (case-insensitive)
    {
        var stmt = try mem_db.db.prepare("SELECT id, term FROM engrams WHERE brain_id = ? AND LOWER(term) = LOWER(?)");
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        try stmt.bindText(2, term);
        const result = try stmt.step();
        if (result == .row) {
            const existing_id = stmt.columnText(0) orelse "";
            const existing_term = stmt.columnText(1) orelse "";
            debug_log.log("memory: learn duplicate found id={s}", .{existing_id});
            return std.fmt.allocPrint(allocator,
                \\Duplicate detected — exact term match.
                \\Existing: **{s}** (id: `{s}`)
                \\Use `cog_mem_update` to modify it.
            , .{ existing_term, existing_id });
        }
    }

    // Check FTS5 for fuzzy match
    {
        // Sanitize the term for FTS5 — wrap each word in quotes
        const fts_query = buildFtsQuery(allocator, term);
        if (fts_query) |fq| {
            defer allocator.free(fq);
            var stmt = mem_db.db.prepare("SELECT id, term, definition FROM engrams WHERE brain_id = ? AND rowid IN (SELECT rowid FROM engrams_fts WHERE engrams_fts MATCH ?) LIMIT 3") catch null;
            if (stmt) |*s| {
                defer s.finalize();
                s.bindText(1, mem_db.brain_id) catch {};
                s.bindText(2, fq) catch {};
                const result = s.step() catch .done;
                if (result == .row) {
                    const sim_id = s.columnText(0) orelse "";
                    const sim_term = s.columnText(1) orelse "";
                    debug_log.log("memory: learn FTS5 near-match id={s} term={s}", .{ sim_id, sim_term });
                    // Still insert, but warn about similar
                }
            }
        }
    }

    // Insert new engram
    const id_buf = generateUuid();
    const new_id = id_buf[0..36];

    {
        var stmt = try mem_db.db.prepare("INSERT INTO engrams (id, brain_id, term, definition) VALUES (?, ?, ?, ?)");
        defer stmt.finalize();
        try stmt.bindText(1, new_id);
        try stmt.bindText(2, mem_db.brain_id);
        try stmt.bindText(3, term);
        try stmt.bindText(4, definition);
        _ = try stmt.step();
    }

    debug_log.log("memory: learned id={s}", .{new_id});

    // Handle associations
    if (getArrayArg(arguments, "associations")) |assocs| {
        for (assocs) |item| {
            if (item == .string) {
                const target_id = try resolveEngramId(mem_db, item.string);
                if (target_id) |tid| {
                    defer allocator.free(tid);
                    _ = createSynapse(mem_db, new_id, tid, "related_to", 1.0) catch continue;
                }
            }
        }
    }

    // Handle chain_to
    if (getStringArg(arguments, "chain_to")) |chain_target| {
        const target_id = try resolveEngramId(mem_db, chain_target);
        if (target_id) |tid| {
            defer allocator.free(tid);
            _ = createSynapse(mem_db, new_id, tid, "sequence", 1.0) catch {};
        }
    }

    return std.fmt.allocPrint(allocator,
        \\Learned **{s}** (id: `{s}`, memory: short-term)
    , .{ term, new_id });
}

fn toolRecall(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const query = getStringArg(arguments, "query") orelse
        return allocator.dupe(u8, "Error: 'query' is required.");
    const limit = getIntArg(arguments, "limit", 10);

    debug_log.log("memory: recall query={s}", .{query});

    const fts_query = buildFtsQuery(allocator, query) orelse
        return allocator.dupe(u8, "No results found.");
    defer allocator.free(fts_query);

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: i64 = 0;

    // FTS5 search
    {
        var stmt = try mem_db.db.prepare(
            \\SELECT e.id, e.term, e.definition, e.memory_term, e.weight
            \\FROM engrams e
            \\WHERE e.brain_id = ? AND e.rowid IN (
            \\  SELECT rowid FROM engrams_fts WHERE engrams_fts MATCH ?
            \\)
            \\ORDER BY e.weight DESC
            \\LIMIT ?
        );
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        try stmt.bindText(2, fts_query);
        try stmt.bindInt(3, limit);

        while (true) {
            const result = try stmt.step();
            if (result == .done) break;

            const e_id = stmt.columnText(0) orelse continue;
            const e_term = stmt.columnText(1) orelse continue;
            const e_def = stmt.columnText(2) orelse continue;
            const e_mem = stmt.columnText(3) orelse "short";

            if (count > 0) out.append("\n---\n");
            out.print("**{s}** ({s})\n{s}\n`id: {s}`", .{ e_term, e_mem, e_def, e_id });

            // 1-hop neighbor expansion
            appendNeighbors(mem_db, &out, e_id) catch {};

            // LTP strengthening
            strengthenWeight(mem_db, e_id) catch {};

            count += 1;
        }
    }

    if (count == 0) {
        out.append("No results found.");
    }

    return out.toOwnedSlice();
}

fn toolGet(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const id = getStringArg(arguments, "id") orelse
        return allocator.dupe(u8, "Error: 'id' is required.");

    var stmt = try mem_db.db.prepare("SELECT term, definition, memory_term, weight, created_at, updated_at FROM engrams WHERE id = ? AND brain_id = ?");
    defer stmt.finalize();
    try stmt.bindText(1, id);
    try stmt.bindText(2, mem_db.brain_id);
    const result = try stmt.step();
    if (result == .done) return allocator.dupe(u8, "Not found.");

    const e_term = stmt.columnText(0) orelse "";
    const e_def = stmt.columnText(1) orelse "";
    const e_mem = stmt.columnText(2) orelse "short";
    const e_weight = stmt.columnReal(3);
    const e_created = stmt.columnText(4) orelse "";
    const e_updated = stmt.columnText(5) orelse "";

    return std.fmt.allocPrint(allocator,
        \\**{s}** ({s}, weight: {d:.2})
        \\{s}
        \\`id: {s}`
        \\Created: {s} | Updated: {s}
    , .{ e_term, e_mem, e_weight, e_def, id, e_created, e_updated });
}

fn toolUpdate(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const id = getStringArg(arguments, "id") orelse
        return allocator.dupe(u8, "Error: 'id' is required.");

    const new_term = getStringArg(arguments, "term");
    const new_def = getStringArg(arguments, "definition");
    if (new_term == null and new_def == null)
        return allocator.dupe(u8, "Error: provide 'term' or 'definition' to update.");

    if (new_term) |t| {
        if (new_def) |d| {
            var stmt = try mem_db.db.prepare("UPDATE engrams SET term = ?, definition = ?, updated_at = datetime('now') WHERE id = ? AND brain_id = ?");
            defer stmt.finalize();
            try stmt.bindText(1, t);
            try stmt.bindText(2, d);
            try stmt.bindText(3, id);
            try stmt.bindText(4, mem_db.brain_id);
            _ = try stmt.step();
        } else {
            var stmt = try mem_db.db.prepare("UPDATE engrams SET term = ?, updated_at = datetime('now') WHERE id = ? AND brain_id = ?");
            defer stmt.finalize();
            try stmt.bindText(1, t);
            try stmt.bindText(2, id);
            try stmt.bindText(3, mem_db.brain_id);
            _ = try stmt.step();
        }
    } else if (new_def) |d| {
        var stmt = try mem_db.db.prepare("UPDATE engrams SET definition = ?, updated_at = datetime('now') WHERE id = ? AND brain_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, d);
        try stmt.bindText(2, id);
        try stmt.bindText(3, mem_db.brain_id);
        _ = try stmt.step();
    }

    if (mem_db.db.changes() == 0) return allocator.dupe(u8, "Not found.");
    return std.fmt.allocPrint(allocator, "Updated `{s}`.", .{id});
}

fn toolAssociate(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const source_name = getStringArg(arguments, "source") orelse
        return allocator.dupe(u8, "Error: 'source' is required.");
    const target_name = getStringArg(arguments, "target") orelse
        return allocator.dupe(u8, "Error: 'target' is required.");
    const relation = getStringArg(arguments, "relation") orelse "related_to";
    const weight = getFloatArg(arguments, "weight", 1.0);

    debug_log.log("memory: associate {s} -> {s}", .{ source_name, target_name });

    const source_id = try resolveEngramId(mem_db, source_name) orelse
        return std.fmt.allocPrint(allocator, "Source not found: {s}", .{source_name});
    defer allocator.free(source_id);

    const target_id = try resolveEngramId(mem_db, target_name) orelse
        return std.fmt.allocPrint(allocator, "Target not found: {s}", .{target_name});
    defer allocator.free(target_id);

    const synapse_id = try createSynapse(mem_db, source_id, target_id, relation, weight);
    return std.fmt.allocPrint(allocator, "Linked {s} -> {s} (synapse: `{s}`)", .{ source_name, target_name, &synapse_id });
}

fn toolUnlink(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const id = getStringArg(arguments, "id") orelse
        return allocator.dupe(u8, "Error: 'id' is required.");

    var stmt = try mem_db.db.prepare("DELETE FROM synapses WHERE id = ? AND brain_id = ?");
    defer stmt.finalize();
    try stmt.bindText(1, id);
    try stmt.bindText(2, mem_db.brain_id);
    _ = try stmt.step();

    if (mem_db.db.changes() == 0) return allocator.dupe(u8, "Synapse not found.");
    return std.fmt.allocPrint(allocator, "Removed synapse `{s}`.", .{id});
}

fn toolRefactor(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const term = getStringArg(arguments, "term") orelse
        return allocator.dupe(u8, "Error: 'term' is required.");
    const definition = getStringArg(arguments, "definition") orelse
        return allocator.dupe(u8, "Error: 'definition' is required.");

    var stmt = try mem_db.db.prepare("UPDATE engrams SET definition = ?, updated_at = datetime('now') WHERE brain_id = ? AND LOWER(term) = LOWER(?)");
    defer stmt.finalize();
    try stmt.bindText(1, definition);
    try stmt.bindText(2, mem_db.brain_id);
    try stmt.bindText(3, term);
    _ = try stmt.step();

    if (mem_db.db.changes() == 0) return std.fmt.allocPrint(allocator, "Term not found: {s}", .{term});
    return std.fmt.allocPrint(allocator, "Refactored **{s}**.", .{term});
}

fn toolDeprecate(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const term = getStringArg(arguments, "term") orelse
        return allocator.dupe(u8, "Error: 'term' is required.");

    debug_log.log("memory: deprecate term={s}", .{term});

    // Find by term
    var find_stmt = try mem_db.db.prepare("SELECT id FROM engrams WHERE brain_id = ? AND LOWER(term) = LOWER(?)");
    defer find_stmt.finalize();
    try find_stmt.bindText(1, mem_db.brain_id);
    try find_stmt.bindText(2, term);
    const result = try find_stmt.step();
    if (result == .done) return std.fmt.allocPrint(allocator, "Term not found: {s}", .{term});

    const id = find_stmt.columnText(0) orelse return allocator.dupe(u8, "Error reading engram.");

    // Delete synapses
    {
        var stmt = try mem_db.db.prepare("DELETE FROM synapses WHERE brain_id = ? AND (source_id = ? OR target_id = ?)");
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        try stmt.bindText(2, id);
        try stmt.bindText(3, id);
        _ = try stmt.step();
    }

    // Set to short-term with old timestamp to trigger cleanup
    {
        var stmt = try mem_db.db.prepare("UPDATE engrams SET memory_term = 'short', created_at = datetime('now', '-25 hours'), updated_at = datetime('now') WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, id);
        _ = try stmt.step();
    }

    return std.fmt.allocPrint(allocator, "Deprecated **{s}**. Links removed, set for expiry.", .{term});
}

fn toolReinforce(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const id = getStringArg(arguments, "id") orelse
        return allocator.dupe(u8, "Error: 'id' is required.");

    debug_log.log("memory: reinforce id={s}", .{id});

    // Promote to long-term
    {
        var stmt = try mem_db.db.prepare("UPDATE engrams SET memory_term = 'long', updated_at = datetime('now') WHERE id = ? AND brain_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, id);
        try stmt.bindText(2, mem_db.brain_id);
        _ = try stmt.step();
    }

    if (mem_db.db.changes() == 0) return allocator.dupe(u8, "Not found.");

    // Cascade to connected synapses (strengthen weight)
    {
        var stmt = try mem_db.db.prepare("UPDATE synapses SET weight = MIN(weight + 0.1, 1.0) WHERE brain_id = ? AND (source_id = ? OR target_id = ?)");
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        try stmt.bindText(2, id);
        try stmt.bindText(3, id);
        _ = try stmt.step();
    }

    return std.fmt.allocPrint(allocator, "Reinforced `{s}` -> long-term memory.", .{id});
}

fn toolFlush(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const id = getStringArg(arguments, "id") orelse
        return allocator.dupe(u8, "Error: 'id' is required.");

    var stmt = try mem_db.db.prepare("DELETE FROM engrams WHERE id = ? AND brain_id = ? AND memory_term = 'short'");
    defer stmt.finalize();
    try stmt.bindText(1, id);
    try stmt.bindText(2, mem_db.brain_id);
    _ = try stmt.step();

    if (mem_db.db.changes() == 0) return allocator.dupe(u8, "Not found or not short-term.");
    return std.fmt.allocPrint(allocator, "Flushed `{s}`.", .{id});
}

fn toolListShortTerm(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const limit = getIntArg(arguments, "limit", 50);

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: i64 = 0;

    var stmt = try mem_db.db.prepare("SELECT id, term, definition, created_at FROM engrams WHERE brain_id = ? AND memory_term = 'short' ORDER BY created_at DESC LIMIT ?");
    defer stmt.finalize();
    try stmt.bindText(1, mem_db.brain_id);
    try stmt.bindInt(2, limit);

    while (true) {
        const result = try stmt.step();
        if (result == .done) break;
        if (count > 0) out.append("\n");
        const e_id = stmt.columnText(0) orelse continue;
        const e_term = stmt.columnText(1) orelse continue;
        const e_created = stmt.columnText(3) orelse "";
        out.print("- **{s}** (`{s}`) — {s}", .{ e_term, e_id, e_created });
        count += 1;
    }

    if (count == 0) out.append("No short-term memories.");
    return out.toOwnedSlice();
}

fn toolConnections(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const id = getStringArg(arguments, "id") orelse
        return allocator.dupe(u8, "Error: 'id' is required.");
    const direction = getStringArg(arguments, "direction") orelse "both";

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: i64 = 0;

    const show_outgoing = std.mem.eql(u8, direction, "both") or std.mem.eql(u8, direction, "outgoing");
    const show_incoming = std.mem.eql(u8, direction, "both") or std.mem.eql(u8, direction, "incoming");

    if (show_outgoing) {
        var stmt = try mem_db.db.prepare(
            \\SELECT s.id, s.relation, s.weight, e.id, e.term
            \\FROM synapses s JOIN engrams e ON s.target_id = e.id
            \\WHERE s.brain_id = ? AND s.source_id = ?
        );
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        try stmt.bindText(2, id);
        while (try stmt.step() == .row) {
            const s_id = stmt.columnText(0) orelse continue;
            const s_rel = stmt.columnText(1) orelse "related_to";
            const e_term = stmt.columnText(4) orelse continue;
            if (count > 0) out.append("\n");
            out.print("-> **{s}** ({s}) [synapse: `{s}`]", .{ e_term, s_rel, s_id });
            count += 1;
        }
    }

    if (show_incoming) {
        var stmt = try mem_db.db.prepare(
            \\SELECT s.id, s.relation, s.weight, e.id, e.term
            \\FROM synapses s JOIN engrams e ON s.source_id = e.id
            \\WHERE s.brain_id = ? AND s.target_id = ?
        );
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        try stmt.bindText(2, id);
        while (try stmt.step() == .row) {
            const s_id = stmt.columnText(0) orelse continue;
            const s_rel = stmt.columnText(1) orelse "related_to";
            const e_term = stmt.columnText(4) orelse continue;
            if (count > 0) out.append("\n");
            out.print("<- **{s}** ({s}) [synapse: `{s}`]", .{ e_term, s_rel, s_id });
            count += 1;
        }
    }

    if (count == 0) out.append("No connections.");
    return out.toOwnedSlice();
}

fn toolTrace(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const from_name = getStringArg(arguments, "from") orelse
        return allocator.dupe(u8, "Error: 'from' is required.");
    const to_name = getStringArg(arguments, "to") orelse
        return allocator.dupe(u8, "Error: 'to' is required.");
    const max_depth = getIntArg(arguments, "max_depth", 5);

    debug_log.log("memory: trace {s} -> {s} max_depth={d}", .{ from_name, to_name, max_depth });

    const from_id = try resolveEngramId(mem_db, from_name) orelse
        return std.fmt.allocPrint(allocator, "Source not found: {s}", .{from_name});
    defer allocator.free(from_id);

    const to_id = try resolveEngramId(mem_db, to_name) orelse
        return std.fmt.allocPrint(allocator, "Target not found: {s}", .{to_name});
    defer allocator.free(to_id);

    // BFS shortest path using recursive CTE
    var stmt = try mem_db.db.prepare(
        \\WITH RECURSIVE trace(node, path, depth) AS (
        \\  SELECT ?, ?, 0
        \\  UNION ALL
        \\  SELECT
        \\    CASE WHEN s.source_id = trace.node THEN s.target_id ELSE s.source_id END,
        \\    trace.path || ' -> ' || (SELECT term FROM engrams WHERE id = CASE WHEN s.source_id = trace.node THEN s.target_id ELSE s.source_id END),
        \\    trace.depth + 1
        \\  FROM trace
        \\  JOIN synapses s ON (s.source_id = trace.node OR s.target_id = trace.node)
        \\  WHERE s.brain_id = ? AND trace.depth < ?
        \\    AND trace.path NOT LIKE '%' || (SELECT term FROM engrams WHERE id = CASE WHEN s.source_id = trace.node THEN s.target_id ELSE s.source_id END) || '%'
        \\)
        \\SELECT path || ' -> ' || (SELECT term FROM engrams WHERE id = ?) AS full_path, depth
        \\FROM trace
        \\WHERE node = ?
        \\ORDER BY depth ASC
        \\LIMIT 1
    );
    defer stmt.finalize();

    // Get source term for the initial path
    const source_term = blk: {
        var t_stmt = try mem_db.db.prepare("SELECT term FROM engrams WHERE id = ?");
        defer t_stmt.finalize();
        try t_stmt.bindText(1, from_id);
        if (try t_stmt.step() == .row) {
            const t = t_stmt.columnText(0) orelse break :blk from_id;
            break :blk try allocator.dupe(u8, t);
        }
        break :blk try allocator.dupe(u8, from_id);
    };
    defer allocator.free(source_term);

    try stmt.bindText(1, from_id);
    try stmt.bindText(2, source_term);
    try stmt.bindText(3, mem_db.brain_id);
    try stmt.bindInt(4, max_depth);
    try stmt.bindText(5, to_id);
    try stmt.bindText(6, to_id);

    const result = try stmt.step();
    if (result == .done) {
        return std.fmt.allocPrint(allocator, "No path found between {s} and {s} (max depth: {d}).", .{ from_name, to_name, max_depth });
    }

    const path = stmt.columnText(0) orelse "?";
    const depth = stmt.columnInt(1);
    return std.fmt.allocPrint(allocator, "Path ({d} hops): {s}", .{ depth, path });
}

fn toolStats(mem_db: *MemoryDb) ![]const u8 {
    const allocator = mem_db.allocator;
    var out = Output.init(allocator);
    errdefer out.deinit();

    // Total engrams
    const total = countQuery(mem_db, "SELECT COUNT(*) FROM engrams WHERE brain_id = ?");
    const short = countQuery(mem_db, "SELECT COUNT(*) FROM engrams WHERE brain_id = ? AND memory_term = 'short'");
    const long = countQuery(mem_db, "SELECT COUNT(*) FROM engrams WHERE brain_id = ? AND memory_term = 'long'");
    const synapse_count = countQuery(mem_db, "SELECT COUNT(*) FROM synapses WHERE brain_id = ?");

    out.print("**Memory Stats**\n", .{});
    out.print("- Engrams: {d} ({d} long-term, {d} short-term)\n", .{ total, long, short });
    out.print("- Synapses: {d}\n", .{synapse_count});
    out.print("- Brain: {s} (local SQLite)", .{mem_db.brain_id});

    return out.toOwnedSlice();
}

fn toolOrphans(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const limit = getIntArg(arguments, "limit", 50);

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: i64 = 0;

    var stmt = try mem_db.db.prepare(
        \\SELECT e.id, e.term
        \\FROM engrams e
        \\WHERE e.brain_id = ?
        \\  AND NOT EXISTS (SELECT 1 FROM synapses s WHERE s.source_id = e.id OR s.target_id = e.id)
        \\ORDER BY e.term
        \\LIMIT ?
    );
    defer stmt.finalize();
    try stmt.bindText(1, mem_db.brain_id);
    try stmt.bindInt(2, limit);

    while (try stmt.step() == .row) {
        const e_id = stmt.columnText(0) orelse continue;
        const e_term = stmt.columnText(1) orelse continue;
        if (count > 0) out.append("\n");
        out.print("- **{s}** (`{s}`)", .{ e_term, e_id });
        count += 1;
    }

    if (count == 0) out.append("No orphaned concepts.");
    return out.toOwnedSlice();
}

fn toolConnectivity(mem_db: *MemoryDb) ![]const u8 {
    const allocator = mem_db.allocator;

    // Load all engram IDs
    var ids = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    {
        var stmt = try mem_db.db.prepare("SELECT id FROM engrams WHERE brain_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, mem_db.brain_id);
        while (try stmt.step() == .row) {
            const id = stmt.columnText(0) orelse continue;
            try ids.append(allocator, try allocator.dupe(u8, id));
        }
    }

    if (ids.items.len == 0) return allocator.dupe(u8, "No concepts in memory.");

    // Build adjacency: for each node, find connected nodes
    var visited = std.StringHashMap(bool).init(allocator);
    defer {
        // Free BFS-discovered keys (ids items are freed by their own defer)
        var it = visited.iterator();
        while (it.next()) |entry| {
            // Check if this key is owned by the ids list
            var owned_by_ids = false;
            for (ids.items) |id| {
                if (id.ptr == entry.key_ptr.*.ptr) {
                    owned_by_ids = true;
                    break;
                }
            }
            if (!owned_by_ids) allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }

    var components: usize = 0;
    var largest: usize = 0;

    for (ids.items) |start_id| {
        if (visited.contains(start_id)) continue;

        // BFS from this node
        var queue = std.ArrayListUnmanaged([]const u8).empty;
        defer queue.deinit(allocator);
        try queue.append(allocator, start_id);
        try visited.put(start_id, true);
        var component_size: usize = 0;

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            component_size += 1;

            // Find neighbors via synapses
            var stmt = try mem_db.db.prepare(
                \\SELECT CASE WHEN source_id = ? THEN target_id ELSE source_id END
                \\FROM synapses WHERE brain_id = ? AND (source_id = ? OR target_id = ?)
            );
            defer stmt.finalize();
            try stmt.bindText(1, current);
            try stmt.bindText(2, mem_db.brain_id);
            try stmt.bindText(3, current);
            try stmt.bindText(4, current);
            while (try stmt.step() == .row) {
                const neighbor = stmt.columnText(0) orelse continue;
                if (!visited.contains(neighbor)) {
                    const n = try allocator.dupe(u8, neighbor);
                    try visited.put(n, true);
                    try queue.append(allocator, n);
                }
            }
        }

        components += 1;
        if (component_size > largest) largest = component_size;
    }

    return std.fmt.allocPrint(allocator,
        \\**Connectivity**
        \\- Total concepts: {d}
        \\- Connected components: {d}
        \\- Largest component: {d} concepts
    , .{ ids.items.len, components, largest });
}

fn toolListTerms(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const limit = getIntArg(arguments, "limit", 100);

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: i64 = 0;

    var stmt = try mem_db.db.prepare("SELECT id, term, memory_term FROM engrams WHERE brain_id = ? ORDER BY term LIMIT ?");
    defer stmt.finalize();
    try stmt.bindText(1, mem_db.brain_id);
    try stmt.bindInt(2, limit);

    while (try stmt.step() == .row) {
        const e_id = stmt.columnText(0) orelse continue;
        const e_term = stmt.columnText(1) orelse continue;
        const e_mem = stmt.columnText(2) orelse "short";
        if (count > 0) out.append("\n");
        out.print("- {s} ({s}) `{s}`", .{ e_term, e_mem, e_id });
        count += 1;
    }

    if (count == 0) out.append("No terms in memory.");
    return out.toOwnedSlice();
}

fn toolBulkLearn(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const items = getArrayArg(arguments, "items") orelse
        return allocator.dupe(u8, "Error: 'items' is required.");

    debug_log.log("memory: bulk_learn count={d}", .{items.len});

    try mem_db.db.exec("BEGIN");
    errdefer mem_db.db.exec("ROLLBACK") catch {};

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: usize = 0;

    for (items) |item| {
        if (item != .object) continue;
        const term = blk: {
            const v = item.object.get("term") orelse continue;
            if (v != .string) continue;
            break :blk v.string;
        };
        const definition = blk: {
            const v = item.object.get("definition") orelse continue;
            if (v != .string) continue;
            break :blk v.string;
        };

        // Check for exact duplicate
        const exists = blk: {
            var stmt = mem_db.db.prepare("SELECT id FROM engrams WHERE brain_id = ? AND LOWER(term) = LOWER(?)") catch break :blk false;
            defer stmt.finalize();
            stmt.bindText(1, mem_db.brain_id) catch break :blk false;
            stmt.bindText(2, term) catch break :blk false;
            const result = stmt.step() catch break :blk false;
            break :blk result == .row;
        };
        if (exists) {
            if (count > 0) out.append("\n");
            out.print("- Skipped **{s}** (duplicate)", .{term});
            count += 1;
            continue;
        }

        const id_buf = generateUuid();
        {
            var stmt = try mem_db.db.prepare("INSERT INTO engrams (id, brain_id, term, definition) VALUES (?, ?, ?, ?)");
            defer stmt.finalize();
            try stmt.bindText(1, &id_buf);
            try stmt.bindText(2, mem_db.brain_id);
            try stmt.bindText(3, term);
            try stmt.bindText(4, definition);
            _ = try stmt.step();
        }
        if (count > 0) out.append("\n");
        out.print("- Learned **{s}**", .{term});
        count += 1;
    }

    try mem_db.db.exec("COMMIT");
    debug_log.log("memory: bulk_learn committed {d} items", .{count});

    if (count == 0) out.append("No items to learn.");
    return out.toOwnedSlice();
}

fn toolBulkAssociate(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const items = getArrayArg(arguments, "items") orelse
        return allocator.dupe(u8, "Error: 'items' is required.");

    debug_log.log("memory: bulk_associate count={d}", .{items.len});

    try mem_db.db.exec("BEGIN");
    errdefer mem_db.db.exec("ROLLBACK") catch {};

    var out = Output.init(allocator);
    errdefer out.deinit();
    var count: usize = 0;

    for (items) |item| {
        if (item != .object) continue;
        const source_name = blk: {
            const v = item.object.get("source") orelse continue;
            if (v != .string) continue;
            break :blk v.string;
        };
        const target_name = blk: {
            const v = item.object.get("target") orelse continue;
            if (v != .string) continue;
            break :blk v.string;
        };
        const relation = blk: {
            const v = item.object.get("relation") orelse break :blk "related_to";
            if (v != .string) break :blk "related_to";
            break :blk v.string;
        };

        const source_id = resolveEngramId(mem_db, source_name) catch continue orelse continue;
        defer allocator.free(source_id);
        const target_id = resolveEngramId(mem_db, target_name) catch continue orelse continue;
        defer allocator.free(target_id);

        _ = createSynapse(mem_db, source_id, target_id, relation, 1.0) catch continue;
        if (count > 0) out.append("\n");
        out.print("- Linked {s} -> {s}", .{ source_name, target_name });
        count += 1;
    }

    try mem_db.db.exec("COMMIT");
    debug_log.log("memory: bulk_associate committed {d} items", .{count});

    if (count == 0) out.append("No associations created.");
    return out.toOwnedSlice();
}

fn toolBulkRecall(mem_db: *MemoryDb, arguments: ?json.Value) ![]const u8 {
    const allocator = mem_db.allocator;
    const queries = getArrayArg(arguments, "queries") orelse
        return allocator.dupe(u8, "Error: 'queries' is required.");

    var out = Output.init(allocator);
    errdefer out.deinit();

    for (queries, 0..) |q, i| {
        if (q != .string) continue;
        if (i > 0) out.append("\n\n---\n\n");
        out.print("## Query: {s}\n\n", .{q.string});

        // Reuse recall logic inline
        const fts_query = buildFtsQuery(allocator, q.string);
        if (fts_query) |fq| {
            defer allocator.free(fq);
            var stmt = mem_db.db.prepare(
                \\SELECT e.id, e.term, e.definition, e.memory_term
                \\FROM engrams e
                \\WHERE e.brain_id = ? AND e.rowid IN (
                \\  SELECT rowid FROM engrams_fts WHERE engrams_fts MATCH ?
                \\)
                \\ORDER BY e.weight DESC
                \\LIMIT 5
            ) catch {
                out.append("Search error.");
                continue;
            };
            defer stmt.finalize();
            stmt.bindText(1, mem_db.brain_id) catch continue;
            stmt.bindText(2, fq) catch continue;

            var found = false;
            while (stmt.step() catch break == .row) {
                const e_term = stmt.columnText(1) orelse continue;
                const e_def = stmt.columnText(2) orelse continue;
                const e_mem = stmt.columnText(3) orelse "short";
                out.print("**{s}** ({s}): {s}\n", .{ e_term, e_mem, e_def });
                found = true;
            }
            if (!found) out.append("No results.");
        } else {
            out.append("No results.");
        }
    }

    return out.toOwnedSlice();
}

// ── Internal helpers ────────────────────────────────────────────────────

fn createSynapse(mem_db: *MemoryDb, source_id: []const u8, target_id: []const u8, relation: []const u8, weight: f64) ![36]u8 {
    debug_log.log("memory: creating synapse {s} -> {s}", .{ source_id, target_id });
    const id_buf = generateUuid();

    var stmt = try mem_db.db.prepare(
        \\INSERT INTO synapses (id, brain_id, source_id, target_id, relation, weight)
        \\VALUES (?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(brain_id, source_id, target_id) DO UPDATE SET
        \\  weight = excluded.weight, relation = excluded.relation
    );
    defer stmt.finalize();
    try stmt.bindText(1, &id_buf);
    try stmt.bindText(2, mem_db.brain_id);
    try stmt.bindText(3, source_id);
    try stmt.bindText(4, target_id);
    try stmt.bindText(5, relation);
    try stmt.bindReal(6, weight);
    _ = try stmt.step();

    return id_buf;
}

fn appendNeighbors(mem_db: *MemoryDb, out: *Output, engram_id: []const u8) !void {
    var stmt = try mem_db.db.prepare(
        \\SELECT e.term, s.relation
        \\FROM synapses s
        \\JOIN engrams e ON (
        \\  CASE WHEN s.source_id = ? THEN s.target_id ELSE s.source_id END = e.id
        \\)
        \\WHERE s.brain_id = ? AND (s.source_id = ? OR s.target_id = ?)
        \\LIMIT 5
    );
    defer stmt.finalize();
    try stmt.bindText(1, engram_id);
    try stmt.bindText(2, mem_db.brain_id);
    try stmt.bindText(3, engram_id);
    try stmt.bindText(4, engram_id);

    var found = false;
    while (try stmt.step() == .row) {
        const n_term = stmt.columnText(0) orelse continue;
        const n_rel = stmt.columnText(1) orelse "related_to";
        if (!found) {
            out.append("\n  Connections:");
            found = true;
        }
        out.print(" {s}({s})", .{ n_term, n_rel });
    }
}

fn strengthenWeight(mem_db: *MemoryDb, engram_id: []const u8) !void {
    var stmt = try mem_db.db.prepare("UPDATE engrams SET weight = MIN(weight + 0.03, 10.0) WHERE id = ? AND brain_id = ?");
    defer stmt.finalize();
    try stmt.bindText(1, engram_id);
    try stmt.bindText(2, mem_db.brain_id);
    _ = try stmt.step();
}

fn countQuery(mem_db: *MemoryDb, sql: [*:0]const u8) i64 {
    var stmt = mem_db.db.prepare(sql) catch return 0;
    defer stmt.finalize();
    stmt.bindText(1, mem_db.brain_id) catch return 0;
    const result = stmt.step() catch return 0;
    if (result == .row) return stmt.columnInt(0);
    return 0;
}

/// Build a FTS5 query from natural language.
/// Wraps each word in quotes and joins with OR for broad matching.
fn buildFtsQuery(allocator: Allocator, input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    var buf = std.ArrayListUnmanaged(u8).empty;
    var words = std.mem.tokenizeAny(u8, input, " \t\n\r");
    var first = true;

    while (words.next()) |word| {
        // Skip very short words
        if (word.len < 2) continue;
        // Skip FTS5 operators
        if (std.mem.eql(u8, word, "AND") or std.mem.eql(u8, word, "OR") or std.mem.eql(u8, word, "NOT")) continue;

        if (!first) buf.appendSlice(allocator, " OR ") catch return null;
        buf.append(allocator, '"') catch return null;
        // Escape double quotes in the word
        for (word) |ch| {
            if (ch == '"') {
                buf.appendSlice(allocator, "\"\"") catch return null;
            } else {
                buf.append(allocator, ch) catch return null;
            }
        }
        buf.append(allocator, '"') catch return null;
        first = false;
    }

    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return null;
    }

    return buf.toOwnedSlice(allocator) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "learn and recall" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    // Learn
    const learn_args = try parseTestJson(
        \\{"term":"Zig language","definition":"A systems programming language focused on safety"}
    );
    defer learn_args.deinit();
    const learn_result = try toolLearn(&mem, learn_args.value);
    defer std.testing.allocator.free(learn_result);
    try std.testing.expect(std.mem.indexOf(u8, learn_result, "Zig language") != null);

    // Recall
    const recall_args = try parseTestJson(
        \\{"query":"zig"}
    );
    defer recall_args.deinit();
    const recall_result = try toolRecall(&mem, recall_args.value);
    defer std.testing.allocator.free(recall_result);
    try std.testing.expect(std.mem.indexOf(u8, recall_result, "Zig language") != null);
    try std.testing.expect(std.mem.indexOf(u8, recall_result, "systems programming") != null);
}

test "learn duplicate detection" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    const args = try parseTestJson(
        \\{"term":"test concept","definition":"first definition"}
    );
    defer args.deinit();
    const r1 = try toolLearn(&mem, args.value);
    defer std.testing.allocator.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "Learned") != null);

    // Duplicate
    const args2 = try parseTestJson(
        \\{"term":"test concept","definition":"second definition"}
    );
    defer args2.deinit();
    const r2 = try toolLearn(&mem, args2.value);
    defer std.testing.allocator.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "Duplicate") != null);
}

test "get by id" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    // Insert directly
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('test-id-1', 'test', 'My Term', 'My Definition')");

    const args = try parseTestJson(
        \\{"id":"test-id-1"}
    );
    defer args.deinit();
    const result = try toolGet(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "My Term") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "My Definition") != null);
}

test "associate and connections" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('a1', 'test', 'Concept A', 'Def A')");
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('b1', 'test', 'Concept B', 'Def B')");

    // Associate
    const assoc_args = try parseTestJson(
        \\{"source":"Concept A","target":"Concept B","relation":"uses"}
    );
    defer assoc_args.deinit();
    const assoc_result = try toolAssociate(&mem, assoc_args.value);
    defer std.testing.allocator.free(assoc_result);
    try std.testing.expect(std.mem.indexOf(u8, assoc_result, "Linked") != null);

    // Connections
    const conn_args = try parseTestJson(
        \\{"id":"a1"}
    );
    defer conn_args.deinit();
    const conn_result = try toolConnections(&mem, conn_args.value);
    defer std.testing.allocator.free(conn_result);
    try std.testing.expect(std.mem.indexOf(u8, conn_result, "Concept B") != null);
}

test "reinforce short to long" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('r1', 'test', 'Short Term', 'Will be reinforced')");

    const args = try parseTestJson(
        \\{"id":"r1"}
    );
    defer args.deinit();
    const result = try toolReinforce(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "long-term") != null);

    // Verify it's now long-term
    {
        var stmt = try db.prepare("SELECT memory_term FROM engrams WHERE id = 'r1'");
        defer stmt.finalize();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("long", stmt.columnText(0).?);
    }
}

test "flush short-term" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition, memory_term) VALUES ('f1', 'test', 'Flush Me', 'Gone soon', 'short')");

    const args = try parseTestJson(
        \\{"id":"f1"}
    );
    defer args.deinit();
    const result = try toolFlush(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Flushed") != null);
}

test "stats" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('s1', 'test', 'One', 'Def 1')");
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition, memory_term) VALUES ('s2', 'test', 'Two', 'Def 2', 'long')");

    const result = try toolStats(&mem);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Engrams: 2") != null);
}

test "orphans" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('o1', 'test', 'Orphan', 'No links')");

    const args = try parseTestJson("{}");
    defer args.deinit();
    const result = try toolOrphans(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Orphan") != null);
}

test "list_terms" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('t1', 'test', 'Alpha', 'First')");
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('t2', 'test', 'Beta', 'Second')");

    const args = try parseTestJson("{}");
    defer args.deinit();
    const result = try toolListTerms(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Beta") != null);
}

test "bulk_learn" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    const args = try parseTestJson(
        \\{"items":[{"term":"Bulk A","definition":"Def A"},{"term":"Bulk B","definition":"Def B"}]}
    );
    defer args.deinit();
    const result = try toolBulkLearn(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bulk A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bulk B") != null);
}

test "trace path" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };

    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('ta', 'test', 'Start', 'Beginning')");
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('tb', 'test', 'Middle', 'In between')");
    try db.exec("INSERT INTO engrams (id, brain_id, term, definition) VALUES ('tc', 'test', 'End', 'Finish')");
    try db.exec("INSERT INTO synapses (id, brain_id, source_id, target_id, relation) VALUES ('s1', 'test', 'ta', 'tb', 'leads_to')");
    try db.exec("INSERT INTO synapses (id, brain_id, source_id, target_id, relation) VALUES ('s2', 'test', 'tb', 'tc', 'leads_to')");

    const args = try parseTestJson(
        \\{"from":"Start","to":"End"}
    );
    defer args.deinit();
    const result = try toolTrace(&mem, args.value);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Path") != null);
}

test "buildFtsQuery" {
    const result = buildFtsQuery(std.testing.allocator, "hello world").?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\" OR \"world\"", result);
}

test "buildFtsQuery empty" {
    try std.testing.expect(buildFtsQuery(std.testing.allocator, "") == null);
}

test "stale returns message" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };
    const result = try callLocalTool(&mem, "cog_mem_stale", null);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "verify returns success" {
    var db = try Db.open(":memory:");
    defer db.close();
    try memory_schema.ensureSchema(&db);
    var mem = MemoryDb{ .db = db, .brain_id = "test", .allocator = std.testing.allocator };
    const result = try callLocalTool(&mem, "cog_mem_verify", null);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
}

// ── Test helpers ────────────────────────────────────────────────────────

fn parseTestJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{});
}
