const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const scip = @import("scip.zig");
const scip_encode = @import("scip_encode.zig");
const protobuf = @import("protobuf.zig");
const help = @import("help_text.zig");
const tui = @import("tui.zig");
const settings_mod = @import("settings.zig");
const paths = @import("paths.zig");
const fs_util = @import("fs_util.zig");
const extensions = @import("extensions.zig");
const tree_sitter_indexer = @import("tree_sitter_indexer.zig");
const debug_log = @import("debug_log.zig");
const path_matcher = @import("path_matcher.zig");
const index_manifest = @import("index_manifest.zig");
const git_state = @import("git_state.zig");

// Advisory file locking via flock(2). Auto-released on close/process exit.
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
const LOCK_EX: c_int = 2;
const LOCK_UN: c_int = 8;

pub const WATCHER_REINDEX_WORKER_COMMAND = "__mcp-watch-reindex";
pub const WATCHER_RESYNC_WORKER_COMMAND = "__mcp-watch-resync";
pub const MAX_WATCHER_REINDEX_FILES: usize = 256;
pub const MAX_WATCHER_REINDEX_ARG_BYTES: usize = 64 * 1024;

/// Acquire an exclusive advisory lock on .cog/index.lock.
/// Blocks until the lock is acquired. Returns the lock fd, or null on failure.
fn acquireIndexLock(allocator: std.mem.Allocator, cog_dir: []const u8) ?posix.fd_t {
    debug_log.log("acquireIndexLock: {s}/index.lock (cog_dir.len={d})", .{ cog_dir, cog_dir.len });
    const lock_path = std.fmt.allocPrint(allocator, "{s}/index.lock", .{cog_dir}) catch |err| {
        debug_log.log("acquireIndexLock: allocPrint failed: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(lock_path);
    debug_log.log("acquireIndexLock: path allocated, len={d}", .{lock_path.len});
    debug_log.log("acquireIndexLock: opening file", .{});
    const fd = posix.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644) catch |err| {
        debug_log.log("acquireIndexLock: open failed: {s}", .{@errorName(err)});
        return null;
    };
    debug_log.log("acquireIndexLock: fd={d}, calling flock", .{fd});
    if (flock(fd, LOCK_EX) != 0) {
        debug_log.log("acquireIndexLock: flock failed errno={d}", .{std.c._errno().*});
        posix.close(fd);
        return null;
    }
    debug_log.log("acquireIndexLock: acquired fd={d}", .{fd});
    return fd;
}

/// Release the advisory lock and close the fd.
fn releaseIndexLock(fd: posix.fd_t) void {
    _ = flock(fd, LOCK_UN);
    posix.close(fd);
    debug_log.log("releaseIndexLock: released", .{});
}

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
const dim = "\x1B[2m";
const reset = "\x1B[0m";

const ExternalIndexerProgress = struct {
    indexed_count: *usize,
    total_files: usize,
    total_symbols: *usize,
    show_progress: bool,

    fn fileDone(self: *ExternalIndexerProgress, file_path: []const u8) void {
        self.indexed_count.* += 1;
        if (self.show_progress) {
            tui.progressUpdate(self.indexed_count.*, self.total_files, self.total_symbols.*, file_path);
        }
    }

    fn phaseLabel(phase: []const u8) []const u8 {
        if (std.mem.eql(u8, phase, "group_start")) return "zig batch start";
        if (std.mem.eql(u8, phase, "load_requested")) return "zig loading files";
        if (std.mem.eql(u8, phase, "post_resolves")) return "zig resolving symbols";
        if (std.mem.eql(u8, phase, "store_to_scip")) return "zig building scip";
        if (std.mem.eql(u8, phase, "external_symbols")) return "zig collecting externals";
        if (std.mem.eql(u8, phase, "group_done")) return "zig batch complete";
        return phase;
    }

    fn phaseUpdate(self: *ExternalIndexerProgress, phase: []const u8, maybe_path: ?[]const u8) void {
        _ = maybe_path;
        if (!self.show_progress) return;
        tui.progressUpdate(self.indexed_count.*, self.total_files, self.total_symbols.*, phaseLabel(phase));
    }
};

const ProgressEvent = union(enum) {
    ignore: void,
    file_done: []const u8,
    file_error: []const u8,
    phase: struct {
        phase: []const u8,
        path: ?[]const u8,
    },
};

// ── Helpers ─────────────────────────────────────────────────────────────

fn printStdout(text: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writerStreaming(&buf);
    w.interface.writeAll(text) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

pub fn validateWatcherReindexArgs(file_paths: []const []const u8) !void {
    if (file_paths.len == 0) return error.MissingFilePaths;
    if (file_paths.len > MAX_WATCHER_REINDEX_FILES) return error.TooManyFilePaths;

    var total_bytes: usize = 0;
    for (file_paths) |file_path| {
        if (file_path.len == 0) return error.EmptyFilePath;
        if (file_path.len > std.fs.max_path_bytes) return error.FilePathTooLong;
        if (std.mem.indexOfScalar(u8, file_path, 0) != null) return error.InvalidFilePath;

        total_bytes = std.math.add(usize, total_bytes, file_path.len) catch return error.ArgumentsTooLong;
        if (total_bytes > MAX_WATCHER_REINDEX_ARG_BYTES) return error.ArgumentsTooLong;
    }
}

/// How many leading paths of `file_paths` fit in one reindex worker call.
///
/// Returns 0 when the first path can never be passed as a worker argument, so
/// callers escalate to a full resync instead of discarding the batch: a watcher
/// batch that outgrows the argument limits still describes real index changes.
pub fn nextWatcherReindexChunk(file_paths: []const []const u8) usize {
    var count: usize = 0;
    var total_bytes: usize = 0;
    for (file_paths) |file_path| {
        if (count == MAX_WATCHER_REINDEX_FILES) break;
        if (file_path.len == 0 or file_path.len > std.fs.max_path_bytes) break;
        if (std.mem.indexOfScalar(u8, file_path, 0) != null) break;

        const next_bytes = std.math.add(usize, total_bytes, file_path.len) catch break;
        if (next_bytes > MAX_WATCHER_REINDEX_ARG_BYTES) break;
        total_bytes = next_bytes;
        count += 1;
    }
    return count;
}

fn deduplicateFilePaths(allocator: std.mem.Allocator, file_paths: []const []const u8) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var unique: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer unique.deinit(allocator);
    try unique.ensureTotalCapacity(allocator, file_paths.len);

    for (file_paths) |file_path| {
        const entry = try seen.getOrPut(allocator, file_path);
        if (entry.found_existing) continue;
        unique.appendAssumeCapacity(file_path);
    }
    return unique.toOwnedSlice(allocator);
}

pub fn runWatcherReindexWorker(allocator: std.mem.Allocator, file_paths: []const []const u8) !u8 {
    try validateWatcherReindexArgs(file_paths);
    debug_log.log("watcher worker: starting batch files={d}", .{file_paths.len});

    const changed = reindexFiles(allocator, file_paths);
    const exit_code: u8 = if (changed) 0 else 1;
    debug_log.log("watcher worker: completed batch status={d}", .{exit_code});
    return exit_code;
}

pub fn runWatcherResyncWorker(allocator: std.mem.Allocator) u8 {
    debug_log.log("watcher worker: starting configured resync", .{});
    const changed = reindexConfiguredFiles(allocator);
    const exit_code: u8 = if (changed) 0 else 1;
    debug_log.log("watcher worker: completed configured resync status={d}", .{exit_code});
    return exit_code;
}

test "validateWatcherReindexArgs accepts file paths" {
    try validateWatcherReindexArgs(&.{ "src/main.zig", "path with spaces/file.zig" });
}

test "validateWatcherReindexArgs rejects missing paths" {
    try std.testing.expectError(error.MissingFilePaths, validateWatcherReindexArgs(&.{}));
}

test "validateWatcherReindexArgs rejects too many paths" {
    const paths_list = [_][]const u8{"src/main.zig"} ** (MAX_WATCHER_REINDEX_FILES + 1);
    try std.testing.expectError(error.TooManyFilePaths, validateWatcherReindexArgs(&paths_list));
}

test "validateWatcherReindexArgs rejects invalid path arguments" {
    try std.testing.expectError(error.EmptyFilePath, validateWatcherReindexArgs(&.{""}));

    const long_path = [_]u8{'a'} ** (std.fs.max_path_bytes + 1);
    try std.testing.expectError(error.FilePathTooLong, validateWatcherReindexArgs(&.{&long_path}));

    try std.testing.expectError(error.InvalidFilePath, validateWatcherReindexArgs(&.{"src/main\x00.zig"}));
}

test "validateWatcherReindexArgs rejects excessive argument bytes" {
    const path = [_]u8{'a'} ** std.fs.max_path_bytes;
    const path_count = MAX_WATCHER_REINDEX_ARG_BYTES / path.len + 1;
    const paths_list = [_][]const u8{&path} ** path_count;
    try std.testing.expectError(error.ArgumentsTooLong, validateWatcherReindexArgs(&paths_list));
}

test "nextWatcherReindexChunk fills a worker call up to the file limit" {
    const paths_list = [_][]const u8{"src/main.zig"} ** (MAX_WATCHER_REINDEX_FILES + 40);
    const chunk = nextWatcherReindexChunk(&paths_list);
    try std.testing.expectEqual(MAX_WATCHER_REINDEX_FILES, chunk);
    try validateWatcherReindexArgs(paths_list[0..chunk]);
}

test "nextWatcherReindexChunk stops at the argument byte budget" {
    const path = [_]u8{'a'} ** 1024;
    const paths_list = [_][]const u8{&path} ** 200;
    const chunk = nextWatcherReindexChunk(&paths_list);
    try std.testing.expectEqual(MAX_WATCHER_REINDEX_ARG_BYTES / path.len, chunk);
    try validateWatcherReindexArgs(paths_list[0..chunk]);
}

test "nextWatcherReindexChunk reports paths no worker call can carry" {
    const long_path = [_]u8{'a'} ** (std.fs.max_path_bytes + 1);
    try std.testing.expectEqual(@as(usize, 0), nextWatcherReindexChunk(&.{&long_path}));
    try std.testing.expectEqual(@as(usize, 0), nextWatcherReindexChunk(&.{""}));
    try std.testing.expectEqual(@as(usize, 0), nextWatcherReindexChunk(&.{"src/main\x00.zig"}));
    try std.testing.expectEqual(@as(usize, 0), nextWatcherReindexChunk(&.{}));
}

test "nextWatcherReindexChunk covers an oversized batch without dropping paths" {
    const paths_list = [_][]const u8{"src/main.zig"} ** (MAX_WATCHER_REINDEX_FILES * 3 + 7);

    var covered: usize = 0;
    var calls: usize = 0;
    while (covered < paths_list.len) {
        const chunk = nextWatcherReindexChunk(paths_list[covered..]);
        try std.testing.expect(chunk > 0);
        try validateWatcherReindexArgs(paths_list[covered .. covered + chunk]);
        covered += chunk;
        calls += 1;
    }
    try std.testing.expectEqual(paths_list.len, covered);
    try std.testing.expectEqual(@as(usize, 4), calls);
}

test "deduplicateFilePaths keeps first occurrence" {
    const allocator = std.testing.allocator;
    const unique = try deduplicateFilePaths(allocator, &.{ "src/a.zig", "src/b.zig", "src/a.zig", "src/b.zig" });
    defer allocator.free(unique);

    try std.testing.expectEqual(@as(usize, 2), unique.len);
    try std.testing.expectEqualStrings("src/a.zig", unique[0]);
    try std.testing.expectEqualStrings("src/b.zig", unique[1]);
}

pub fn builtinExtensionList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (extensions.builtins) |b| {
            out = out ++ "    " ++ bold ++ b.name ++ reset ++ dim;
            for (b.file_extensions) |ext| {
                out = out ++ " " ++ ext;
            }
            out = out ++ reset ++ "\n";
        }
        return out;
    }
}

pub fn listInstalledBlock(allocator: std.mem.Allocator) ?[]const u8 {
    return listInstalledBlockFiltered(allocator, false);
}

pub fn listInstalledDebugBlock(allocator: std.mem.Allocator) ?[]const u8 {
    return listInstalledBlockFiltered(allocator, true);
}

fn listInstalledBlockFiltered(allocator: std.mem.Allocator, debug_only: bool) ?[]const u8 {
    const installed = extensions.listInstalled(allocator) catch return null;
    defer extensions.freeInstalledList(allocator, installed);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    var count: usize = 0;
    for (installed) |ext| {
        if (debug_only and !ext.has_debugger) continue;
        if (count == 0) {
            w.writeAll(cyan ++ bold ++ "  Installed" ++ reset ++ "\n") catch return null;
        }
        w.writeAll("    " ++ bold) catch return null;
        w.writeAll(ext.name) catch return null;
        w.writeAll(reset ++ dim) catch return null;
        for (ext.file_extensions) |fe| {
            w.writeAll(" ") catch return null;
            w.writeAll(fe) catch return null;
        }
        w.writeAll(reset ++ "\n") catch return null;
        count += 1;
    }
    if (count == 0) return null;
    w.writeAll("\n") catch return null;
    return buf.toOwnedSlice(allocator) catch return null;
}

pub fn builtinDebugExtensionList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (extensions.builtins) |b| {
            if (b.debug == null) continue;
            out = out ++ "    " ++ bold ++ b.name ++ reset ++ dim;
            for (b.file_extensions) |ext| {
                out = out ++ " " ++ ext;
            }
            out = out ++ reset ++ "\n";
        }
        return out;
    }
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

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

// ── Index location ──────────────────────────────────────────────────────

/// Get the path to the index.scip file.
fn getIndexPathQuiet(allocator: std.mem.Allocator) ![]const u8 {
    const cog_dir = try paths.findCogDir(allocator);
    defer allocator.free(cog_dir);
    return std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
}

/// Get the path to the index.scip file and explain missing index state to CLI users.
fn getIndexPath(allocator: std.mem.Allocator) ![]const u8 {
    return getIndexPathQuiet(allocator) catch {
        printErr("error: no .cog directory found. Run " ++ dim ++ "cog code:index" ++ reset ++ " first.\n");
        return error.Explained;
    };
}

// ── CodeIndex ───────────────────────────────────────────────────────────

const DefInfo = struct {
    path: []const u8,
    line: i32,
    end_line: i32 = 0, // end of definition body (from enclosing_range); 0 = unknown
    enclosing_range: ?scip.Range = null,
    kind: i32,
    display_name: []const u8,
    documentation: []const []const u8,
};

const RefInfo = struct {
    path: []const u8,
    line: i32,
    roles: []const u8,
};

const RelationshipInfo = struct {
    symbol: []const u8,
    kind: []const u8,
};

const RelationshipList = std.ArrayListUnmanaged(RelationshipInfo);

const RelationshipDedupKey = struct {
    owner: []const u8,
    symbol: []const u8,
    kind: []const u8,
};

const RelationshipDedupContext = struct {
    pub fn hash(_: @This(), key: RelationshipDedupKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.owner);
        hasher.update("\x00");
        hasher.update(key.symbol);
        hasher.update("\x00");
        hasher.update(key.kind);
        return hasher.final();
    }

    pub fn eql(_: @This(), left: RelationshipDedupKey, right: RelationshipDedupKey) bool {
        return std.mem.eql(u8, left.owner, right.owner) and
            std.mem.eql(u8, left.symbol, right.symbol) and
            std.mem.eql(u8, left.kind, right.kind);
    }
};

const RelationshipDedupSet = std.HashMapUnmanaged(
    RelationshipDedupKey,
    void,
    RelationshipDedupContext,
    std.hash_map.default_max_load_percentage,
);

const FileImport = struct {
    label: []const u8,
    symbol: []const u8,
};

const FileImportList = std.ArrayListUnmanaged(FileImport);

const ImportDedupKey = struct {
    document_path: []const u8,
    label: []const u8,
    symbol: []const u8,
};

const ImportDedupContext = struct {
    pub fn hash(_: @This(), key: ImportDedupKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.document_path);
        hasher.update("\x00");
        hasher.update(key.label);
        hasher.update("\x00");
        hasher.update(key.symbol);
        return hasher.final();
    }

    pub fn eql(_: @This(), left: ImportDedupKey, right: ImportDedupKey) bool {
        return std.mem.eql(u8, left.document_path, right.document_path) and
            std.mem.eql(u8, left.label, right.label) and
            std.mem.eql(u8, left.symbol, right.symbol);
    }
};

const ImportDedupSet = std.HashMapUnmanaged(
    ImportDedupKey,
    void,
    ImportDedupContext,
    std.hash_map.default_max_load_percentage,
);

fn appendDeduplicatedRelationship(
    allocator: std.mem.Allocator,
    seen: *RelationshipDedupSet,
    owner: []const u8,
    list: *RelationshipList,
    relationship: RelationshipInfo,
) !void {
    const entry = try seen.getOrPut(allocator, .{
        .owner = owner,
        .symbol = relationship.symbol,
        .kind = relationship.kind,
    });
    if (entry.found_existing) return;
    try list.append(allocator, relationship);
}

fn appendDeduplicatedImport(
    allocator: std.mem.Allocator,
    seen: *ImportDedupSet,
    document_path: []const u8,
    list: *FileImportList,
    item: FileImport,
) !void {
    const entry = try seen.getOrPut(allocator, .{
        .document_path = document_path,
        .label = item.label,
        .symbol = item.symbol,
    });
    if (entry.found_existing) return;
    try list.append(allocator, item);
}

const RangeEndpoint = struct {
    line: i32,
    char: i32,
};

const EnclosingRangeEntry = struct {
    symbol: []const u8,
    range: scip.Range,
    document_order: usize,
};

const EnclosingRangeIndex = struct {
    entries: []EnclosingRangeEntry,
    max_end_tree: []RangeEndpoint,
    leaf_count: usize,

    fn init(allocator: std.mem.Allocator, source_entries: []const EnclosingRangeEntry) !EnclosingRangeIndex {
        const entries = try allocator.dupe(EnclosingRangeEntry, source_entries);
        return initOwned(allocator, entries);
    }

    fn initForDocument(
        allocator: std.mem.Allocator,
        document: scip.Document,
        definitions: *const std.StringHashMapUnmanaged(DefInfo),
    ) !EnclosingRangeIndex {
        var entry_count: usize = 0;
        for (document.symbols) |symbol| {
            if (symbol.symbol.len == 0) continue;
            if ((definitions.get(symbol.symbol) orelse continue).enclosing_range != null) entry_count += 1;
        }

        const entries = try allocator.alloc(EnclosingRangeEntry, entry_count);
        var entry_index: usize = 0;
        for (document.symbols, 0..) |symbol, document_order| {
            if (symbol.symbol.len == 0) continue;
            const range = (definitions.get(symbol.symbol) orelse continue).enclosing_range orelse continue;
            entries[entry_index] = .{
                .symbol = symbol.symbol,
                .range = range,
                .document_order = document_order,
            };
            entry_index += 1;
        }
        return initOwned(allocator, entries);
    }

    fn initOwned(allocator: std.mem.Allocator, entries: []EnclosingRangeEntry) !EnclosingRangeIndex {
        errdefer allocator.free(entries);
        if (entries.len == 0) {
            return .{
                .entries = entries,
                .max_end_tree = &.{},
                .leaf_count = 0,
            };
        }

        std.mem.sortUnstable(EnclosingRangeEntry, entries, {}, lessThan);

        var leaf_count: usize = 1;
        while (leaf_count < entries.len) {
            leaf_count = std.math.mul(usize, leaf_count, 2) catch return error.OutOfMemory;
        }
        const tree_len = std.math.mul(usize, leaf_count, 2) catch return error.OutOfMemory;
        const max_end_tree = try allocator.alloc(RangeEndpoint, tree_len);
        errdefer allocator.free(max_end_tree);
        @memset(max_end_tree, minimumEndpoint());

        for (entries, 0..) |entry, index| {
            max_end_tree[leaf_count + index] = rangeEnd(entry.range);
        }
        var node = leaf_count;
        while (node > 1) {
            node -= 1;
            max_end_tree[node] = laterEndpoint(max_end_tree[node * 2], max_end_tree[node * 2 + 1]);
        }

        return .{
            .entries = entries,
            .max_end_tree = max_end_tree,
            .leaf_count = leaf_count,
        };
    }

    fn deinit(self: *EnclosingRangeIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        if (self.max_end_tree.len > 0) allocator.free(self.max_end_tree);
        self.* = undefined;
    }

    fn findInnermost(self: *const EnclosingRangeIndex, line: i32, char: i32) ?[]const u8 {
        return self.findInnermostInternal(line, char, null);
    }

    fn findInnermostCounted(self: *const EnclosingRangeIndex, line: i32, char: i32, probes: *usize) ?[]const u8 {
        return self.findInnermostInternal(line, char, probes);
    }

    fn findInnermostInternal(
        self: *const EnclosingRangeIndex,
        line: i32,
        char: i32,
        probes: ?*usize,
    ) ?[]const u8 {
        if (self.entries.len == 0) return null;
        const point: RangeEndpoint = .{ .line = line, .char = char };
        const limit = self.upperBoundStart(point, probes);
        if (limit == 0) return null;
        const entry_index = self.findRightmostCovering(1, 0, self.leaf_count, limit, point, probes) orelse return null;
        return self.entries[entry_index].symbol;
    }

    fn upperBoundStart(self: *const EnclosingRangeIndex, point: RangeEndpoint, probes: ?*usize) usize {
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            countProbe(probes);
            const middle = low + (high - low) / 2;
            if (endpointAtOrBefore(rangeStart(self.entries[middle].range), point)) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    fn findRightmostCovering(
        self: *const EnclosingRangeIndex,
        node: usize,
        start: usize,
        end: usize,
        limit: usize,
        point: RangeEndpoint,
        probes: ?*usize,
    ) ?usize {
        countProbe(probes);
        if (start >= limit or endpointBefore(self.max_end_tree[node], point)) return null;
        if (end - start == 1) return if (start < self.entries.len) start else null;

        const middle = start + (end - start) / 2;
        if (self.findRightmostCovering(node * 2 + 1, middle, end, limit, point, probes)) |index| return index;
        return self.findRightmostCovering(node * 2, start, middle, limit, point, probes);
    }

    fn lessThan(_: void, left: EnclosingRangeEntry, right: EnclosingRangeEntry) bool {
        const left_start = rangeStart(left.range);
        const right_start = rangeStart(right.range);
        if (endpointBefore(left_start, right_start)) return true;
        if (endpointBefore(right_start, left_start)) return false;

        const left_end = rangeEnd(left.range);
        const right_end = rangeEnd(right.range);
        if (endpointBefore(right_end, left_end)) return true;
        if (endpointBefore(left_end, right_end)) return false;
        return left.document_order < right.document_order;
    }

    fn countProbe(probes: ?*usize) void {
        if (probes) |count| count.* += 1;
    }

    fn minimumEndpoint() RangeEndpoint {
        return .{ .line = std.math.minInt(i32), .char = std.math.minInt(i32) };
    }

    fn rangeStart(range: scip.Range) RangeEndpoint {
        return .{ .line = range.start_line, .char = range.start_char };
    }

    fn rangeEnd(range: scip.Range) RangeEndpoint {
        return .{ .line = range.end_line, .char = range.end_char };
    }

    fn endpointBefore(left: RangeEndpoint, right: RangeEndpoint) bool {
        return left.line < right.line or (left.line == right.line and left.char < right.char);
    }

    fn endpointAtOrBefore(left: RangeEndpoint, right: RangeEndpoint) bool {
        return !endpointBefore(right, left);
    }

    fn laterEndpoint(left: RangeEndpoint, right: RangeEndpoint) RangeEndpoint {
        return if (endpointBefore(left, right)) right else left;
    }
};

const FileStat = struct {
    path: []const u8,
    symbol_count: usize,
    import_count: usize,
};

const EntrypointStat = struct {
    symbol: []const u8,
    path: []const u8,
    line: i32,
    end_line: i32,
    score: i32,
};

const SubsystemStat = struct {
    name: []const u8,
    file_count: usize,
    import_count: usize,
};

pub const CodeIndex = struct {
    index: scip.Index,
    symbol_to_defs: std.StringHashMapUnmanaged(DefInfo),
    symbol_to_refs: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(RefInfo)),
    path_to_doc_idx: std.StringHashMapUnmanaged(usize),
    symbol_to_parent: std.StringHashMapUnmanaged([]const u8),
    parent_to_children: std.StringHashMapUnmanaged(RelationshipList),
    symbol_to_relationships: std.StringHashMapUnmanaged(RelationshipList),
    symbol_to_reverse_relationships: std.StringHashMapUnmanaged(RelationshipList),
    file_to_imports: std.StringHashMapUnmanaged(FileImportList),
    symbol_to_calls: std.StringHashMapUnmanaged(RelationshipList),
    symbol_to_callers: std.StringHashMapUnmanaged(RelationshipList),
    /// Backing data buffer for zero-copy protobuf decoder. Must outlive the index.
    backing_data: ?[]const u8 = null,

    fn build(allocator: std.mem.Allocator, index: scip.Index) !CodeIndex {
        var symbol_to_defs: std.StringHashMapUnmanaged(DefInfo) = .empty;
        var symbol_to_refs: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(RefInfo)) = .empty;
        var path_to_doc_idx: std.StringHashMapUnmanaged(usize) = .empty;
        var symbol_to_parent: std.StringHashMapUnmanaged([]const u8) = .empty;
        var parent_to_children: std.StringHashMapUnmanaged(RelationshipList) = .empty;
        var symbol_to_relationships: std.StringHashMapUnmanaged(RelationshipList) = .empty;
        var symbol_to_reverse_relationships: std.StringHashMapUnmanaged(RelationshipList) = .empty;
        var file_to_imports: std.StringHashMapUnmanaged(FileImportList) = .empty;
        var symbol_to_calls: std.StringHashMapUnmanaged(RelationshipList) = .empty;
        var symbol_to_callers: std.StringHashMapUnmanaged(RelationshipList) = .empty;

        var children_seen: RelationshipDedupSet = .empty;
        defer children_seen.deinit(allocator);
        var relationships_seen: RelationshipDedupSet = .empty;
        defer relationships_seen.deinit(allocator);
        var reverse_relationships_seen: RelationshipDedupSet = .empty;
        defer reverse_relationships_seen.deinit(allocator);
        var imports_seen: ImportDedupSet = .empty;
        defer imports_seen.deinit(allocator);
        var calls_seen: RelationshipDedupSet = .empty;
        defer calls_seen.deinit(allocator);
        var callers_seen: RelationshipDedupSet = .empty;
        defer callers_seen.deinit(allocator);

        debug_log.log("CodeIndex.build: pass1 documents={d}", .{index.documents.len});

        // Pass 1: register every document and definition before resolving any
        // relationship. This makes relationship construction independent of
        // SCIP document order.
        for (index.documents, 0..) |doc, doc_idx| {
            try path_to_doc_idx.put(allocator, doc.relative_path, doc_idx);

            for (doc.symbols) |sym| {
                if (sym.symbol.len == 0) continue;

                var def_line: i32 = 0;
                var def_end_line: i32 = 0;
                var enclosing_range: ?scip.Range = null;
                for (doc.occurrences) |occ| {
                    if (!std.mem.eql(u8, occ.symbol, sym.symbol)) continue;
                    if (!scip.SymbolRole.isDefinition(occ.symbol_roles)) continue;
                    def_line = occ.range.start_line;
                    enclosing_range = occ.enclosing_range;
                    if (occ.enclosing_range) |range| def_end_line = range.end_line;
                    break;
                }

                try symbol_to_defs.put(allocator, sym.symbol, .{
                    .path = doc.relative_path,
                    .line = def_line,
                    .end_line = def_end_line,
                    .enclosing_range = enclosing_range,
                    .kind = sym.kind,
                    .display_name = sym.display_name,
                    .documentation = sym.documentation,
                });
            }
        }

        for (index.external_symbols) |sym| {
            if (sym.symbol.len > 0 and !symbol_to_defs.contains(sym.symbol)) {
                try symbol_to_defs.put(allocator, sym.symbol, .{
                    .path = "",
                    .line = 0,
                    .kind = sym.kind,
                    .display_name = sym.display_name,
                    .documentation = sym.documentation,
                });
            }
        }

        debug_log.log("CodeIndex.build: pass2 definitions={d}", .{symbol_to_defs.count()});

        // Pass 2: build containment, declared relationships, references,
        // imports, and call edges against the complete definition table.
        // Each document's enclosing-range index is built and released within
        // its own iteration so peak auxiliary memory stays at one document.
        var enclosing_range_entries: usize = 0;
        for (index.documents) |doc| {
            var enclosing_range_index = try EnclosingRangeIndex.initForDocument(allocator, doc, &symbol_to_defs);
            defer enclosing_range_index.deinit(allocator);
            enclosing_range_entries += enclosing_range_index.entries.len;
            for (doc.symbols) |sym| {
                if (sym.symbol.len == 0) continue;

                if (sym.enclosing_symbol.len > 0) {
                    try symbol_to_parent.put(allocator, sym.symbol, sym.enclosing_symbol);
                    const children_entry = try parent_to_children.getOrPut(allocator, sym.enclosing_symbol);
                    if (!children_entry.found_existing) children_entry.value_ptr.* = .empty;
                    try appendDeduplicatedRelationship(allocator, &children_seen, sym.enclosing_symbol, children_entry.value_ptr, .{
                        .symbol = sym.symbol,
                        .kind = "contains",
                    });
                }

                if (sym.relationships.len == 0) continue;
                const outgoing_entry = try symbol_to_relationships.getOrPut(allocator, sym.symbol);
                if (!outgoing_entry.found_existing) outgoing_entry.value_ptr.* = .empty;

                for (sym.relationships) |rel| {
                    const rel_kind = scip.relationshipKind(rel);
                    try appendDeduplicatedRelationship(allocator, &relationships_seen, sym.symbol, outgoing_entry.value_ptr, .{
                        .symbol = rel.symbol,
                        .kind = rel_kind,
                    });
                    try addSpecializedRelationship(
                        allocator,
                        doc.relative_path,
                        sym.symbol,
                        rel.symbol,
                        rel_kind,
                        &symbol_to_defs,
                        &path_to_doc_idx,
                        &imports_seen,
                        &file_to_imports,
                        &calls_seen,
                        &callers_seen,
                        &symbol_to_calls,
                        &symbol_to_callers,
                    );

                    const reverse_entry = try symbol_to_reverse_relationships.getOrPut(allocator, rel.symbol);
                    if (!reverse_entry.found_existing) reverse_entry.value_ptr.* = .empty;
                    try appendDeduplicatedRelationship(allocator, &reverse_relationships_seen, rel.symbol, reverse_entry.value_ptr, .{
                        .symbol = sym.symbol,
                        .kind = rel_kind,
                    });
                }
            }

            for (doc.occurrences) |occ| {
                if (occ.symbol.len == 0) continue;
                const entry = try symbol_to_refs.getOrPut(allocator, occ.symbol);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(allocator, .{
                    .path = doc.relative_path,
                    .line = occ.range.start_line,
                    .roles = scip.SymbolRole.describe(occ.symbol_roles),
                });

                if ((occ.symbol_roles & scip.SymbolRole.Import) != 0) {
                    const imports_entry = try file_to_imports.getOrPut(allocator, doc.relative_path);
                    if (!imports_entry.found_existing) imports_entry.value_ptr.* = .empty;
                    try appendDeduplicatedImport(allocator, &imports_seen, doc.relative_path, imports_entry.value_ptr, .{
                        .label = resolveImportLabel(displayLabelForSymbol(occ.symbol, &symbol_to_defs), &path_to_doc_idx),
                        .symbol = occ.symbol,
                    });
                } else if (std.mem.startsWith(u8, occ.symbol, "cog/call/")) {
                    const call_name = occ.symbol["cog/call/".len..];
                    const caller_symbol = enclosing_range_index.findInnermost(occ.range.start_line, occ.range.start_char) orelse continue;
                    const callee_symbol = resolveCallTarget(call_name, doc.relative_path, &symbol_to_defs) orelse continue;
                    try addCallEdge(
                        allocator,
                        caller_symbol,
                        callee_symbol,
                        &calls_seen,
                        &callers_seen,
                        &symbol_to_calls,
                        &symbol_to_callers,
                    );
                }
            }
        }

        for (index.external_symbols) |sym| {
            if (sym.relationships.len == 0) continue;
            const outgoing_entry = try symbol_to_relationships.getOrPut(allocator, sym.symbol);
            if (!outgoing_entry.found_existing) outgoing_entry.value_ptr.* = .empty;
            for (sym.relationships) |rel| {
                const rel_kind = scip.relationshipKind(rel);
                try appendDeduplicatedRelationship(allocator, &relationships_seen, sym.symbol, outgoing_entry.value_ptr, .{
                    .symbol = rel.symbol,
                    .kind = rel_kind,
                });
                if (std.mem.eql(u8, rel_kind, "calls")) {
                    try addCallEdge(
                        allocator,
                        sym.symbol,
                        rel.symbol,
                        &calls_seen,
                        &callers_seen,
                        &symbol_to_calls,
                        &symbol_to_callers,
                    );
                }

                const reverse_entry = try symbol_to_reverse_relationships.getOrPut(allocator, rel.symbol);
                if (!reverse_entry.found_existing) reverse_entry.value_ptr.* = .empty;
                try appendDeduplicatedRelationship(allocator, &reverse_relationships_seen, rel.symbol, reverse_entry.value_ptr, .{
                    .symbol = sym.symbol,
                    .kind = rel_kind,
                });
            }
        }

        debug_log.log("CodeIndex.build: pass2 enclosing_ranges={d}", .{enclosing_range_entries});
        debug_log.log("CodeIndex.build: defs={d} refs={d} imports={d} calls={d}", .{ symbol_to_defs.count(), symbol_to_refs.count(), file_to_imports.count(), symbol_to_calls.count() });
        debug_log.log("CodeIndex.build: dedup children={d} relationships={d} reverse={d} imports={d} calls={d} callers={d}", .{
            children_seen.count(),
            relationships_seen.count(),
            reverse_relationships_seen.count(),
            imports_seen.count(),
            calls_seen.count(),
            callers_seen.count(),
        });

        return .{
            .index = index,
            .symbol_to_defs = symbol_to_defs,
            .symbol_to_refs = symbol_to_refs,
            .path_to_doc_idx = path_to_doc_idx,
            .symbol_to_parent = symbol_to_parent,
            .parent_to_children = parent_to_children,
            .symbol_to_relationships = symbol_to_relationships,
            .symbol_to_reverse_relationships = symbol_to_reverse_relationships,
            .file_to_imports = file_to_imports,
            .symbol_to_calls = symbol_to_calls,
            .symbol_to_callers = symbol_to_callers,
        };
    }
    pub fn deinit(self: *CodeIndex, allocator: std.mem.Allocator) void {
        self.symbol_to_defs.deinit(allocator);
        var ref_iter = self.symbol_to_refs.iterator();
        while (ref_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.symbol_to_refs.deinit(allocator);
        self.path_to_doc_idx.deinit(allocator);
        self.symbol_to_parent.deinit(allocator);

        var child_iter = self.parent_to_children.iterator();
        while (child_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.parent_to_children.deinit(allocator);

        var rel_iter = self.symbol_to_relationships.iterator();
        while (rel_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.symbol_to_relationships.deinit(allocator);

        var rev_iter = self.symbol_to_reverse_relationships.iterator();
        while (rev_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.symbol_to_reverse_relationships.deinit(allocator);

        var import_iter = self.file_to_imports.iterator();
        while (import_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.file_to_imports.deinit(allocator);

        var call_iter = self.symbol_to_calls.iterator();
        while (call_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.symbol_to_calls.deinit(allocator);

        var caller_iter = self.symbol_to_callers.iterator();
        while (caller_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.symbol_to_callers.deinit(allocator);
        scip.freeIndex(allocator, &self.index);
        if (self.backing_data) |data| allocator.free(data);
    }

    fn addCallEdge(
        allocator: std.mem.Allocator,
        caller_symbol: []const u8,
        callee_symbol: []const u8,
        calls_seen: *RelationshipDedupSet,
        callers_seen: *RelationshipDedupSet,
        symbol_to_calls: *std.StringHashMapUnmanaged(RelationshipList),
        symbol_to_callers: *std.StringHashMapUnmanaged(RelationshipList),
    ) !void {
        const calls_entry = try symbol_to_calls.getOrPut(allocator, caller_symbol);
        if (!calls_entry.found_existing) calls_entry.value_ptr.* = .empty;
        try appendDeduplicatedRelationship(allocator, calls_seen, caller_symbol, calls_entry.value_ptr, .{
            .symbol = callee_symbol,
            .kind = "calls",
        });

        const callers_entry = try symbol_to_callers.getOrPut(allocator, callee_symbol);
        if (!callers_entry.found_existing) callers_entry.value_ptr.* = .empty;
        try appendDeduplicatedRelationship(allocator, callers_seen, callee_symbol, callers_entry.value_ptr, .{
            .symbol = caller_symbol,
            .kind = "callers",
        });
    }

    fn addSpecializedRelationship(
        allocator: std.mem.Allocator,
        document_path: []const u8,
        source_symbol: []const u8,
        target_symbol: []const u8,
        kind: []const u8,
        defs: *const std.StringHashMapUnmanaged(DefInfo),
        indexed_paths: *const std.StringHashMapUnmanaged(usize),
        imports_seen: *ImportDedupSet,
        file_to_imports: *std.StringHashMapUnmanaged(FileImportList),
        calls_seen: *RelationshipDedupSet,
        callers_seen: *RelationshipDedupSet,
        symbol_to_calls: *std.StringHashMapUnmanaged(RelationshipList),
        symbol_to_callers: *std.StringHashMapUnmanaged(RelationshipList),
    ) !void {
        if (std.mem.eql(u8, kind, "calls")) {
            try addCallEdge(
                allocator,
                source_symbol,
                target_symbol,
                calls_seen,
                callers_seen,
                symbol_to_calls,
                symbol_to_callers,
            );
        } else if (std.mem.eql(u8, kind, "imports")) {
            const imports_entry = try file_to_imports.getOrPut(allocator, document_path);
            if (!imports_entry.found_existing) imports_entry.value_ptr.* = .empty;
            try appendDeduplicatedImport(allocator, imports_seen, document_path, imports_entry.value_ptr, .{
                .label = resolveImportLabel(displayLabelForSymbol(target_symbol, defs), indexed_paths),
                .symbol = target_symbol,
            });
        }
    }

    fn resolveImportLabel(label: []const u8, indexed_paths: *const std.StringHashMapUnmanaged(usize)) []const u8 {
        if (indexed_paths.getKey(label)) |canonical| return canonical;

        const extensions_to_try = [_][]const u8{
            ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".java", ".py", ".go", ".rs", ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp",
        };
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        for (&extensions_to_try) |extension| {
            if (label.len + extension.len > buffer.len) continue;
            @memcpy(buffer[0..label.len], label);
            @memcpy(buffer[label.len..][0..extension.len], extension);
            if (indexed_paths.getKey(buffer[0 .. label.len + extension.len])) |canonical| return canonical;
        }

        const index_files = [_][]const u8{
            "index.js", "index.jsx", "index.mjs", "index.cjs", "index.ts", "index.tsx", "index.mts",
        };
        for (&index_files) |index_file| {
            const separator_len: usize = if (label.len > 0 and label[label.len - 1] == '/') 0 else 1;
            if (label.len + separator_len + index_file.len > buffer.len) continue;
            @memcpy(buffer[0..label.len], label);
            if (separator_len == 1) buffer[label.len] = '/';
            const index_start = label.len + separator_len;
            @memcpy(buffer[index_start..][0..index_file.len], index_file);
            if (indexed_paths.getKey(buffer[0 .. index_start + index_file.len])) |canonical| return canonical;
        }

        return label;
    }

    fn displayLabelForSymbol(symbol: []const u8, defs: *const std.StringHashMapUnmanaged(DefInfo)) []const u8 {
        if (std.mem.startsWith(u8, symbol, "cog/import/")) {
            return symbol["cog/import/".len..];
        }
        if (std.mem.startsWith(u8, symbol, "cog/call/")) {
            return symbol["cog/call/".len..];
        }
        if (defs.get(symbol)) |def| {
            if (def.display_name.len > 0) return def.display_name;
        }
        return scip.extractSymbolName(symbol);
    }

    fn resolveCallTarget(call_name: []const u8, caller_path: []const u8, defs: *const std.StringHashMapUnmanaged(DefInfo)) ?[]const u8 {
        var best_symbol: ?[]const u8 = null;
        var best_score: i32 = -1;
        var iter = defs.iterator();
        while (iter.next()) |entry| {
            const symbol = entry.key_ptr.*;
            const def = entry.value_ptr.*;
            const display_name = if (def.display_name.len > 0) def.display_name else scip.extractSymbolName(symbol);
            if (!std.mem.eql(u8, display_name, call_name)) continue;

            var score: i32 = 0;
            if (std.mem.eql(u8, def.path, caller_path)) score += 100;
            if (!CodeIndex.pathIsTest(def.path)) score += 25;
            score += @as(i32, @intCast(10 - @min(CodeIndex.countPathSeparators(def.path), 10)));

            if (score > best_score) {
                best_score = score;
                best_symbol = symbol;
            }
        }
        return best_symbol;
    }

    /// Find symbols matching a name (searches display_name and extracted name).
    /// Returns matches sorted by relevance score (exact match > non-test > partial match).
    /// Supports glob patterns (* and ?) when the name contains wildcard characters.
    /// Supports alternation via '|' to match any of several names (e.g. "banner|header|splash").
    /// When file_filter is set, only symbols in matching files are returned.
    /// Caller must call `matches.deinit(allocator)` when done.
    fn findSymbol(self: *const CodeIndex, allocator: std.mem.Allocator, name: []const u8, kind_filter: ?[]const u8, file_filter: ?[]const u8) !MatchList {
        // Split on '|' for alternation (e.g. "banner|header|splash")
        const alternatives = splitAlternatives(name);

        var matches: MatchList = .empty;
        var iter = self.symbol_to_defs.iterator();
        while (iter.next()) |entry| {
            const sym_name = entry.key_ptr.*;
            const def = entry.value_ptr.*;
            const extracted = scip.extractSymbolName(sym_name);

            var matched = false;
            var matched_exact = false;

            for (alternatives.items()) |alt| {
                const is_glob = hasGlobChars(alt);

                // Match against display_name
                const display_match = if (is_glob)
                    (def.display_name.len > 0 and nameGlobMatch(alt, def.display_name))
                else
                    (def.display_name.len > 0 and std.ascii.eqlIgnoreCase(def.display_name, alt));

                // Match against extracted name from symbol string
                const extracted_match = if (is_glob)
                    nameGlobMatch(alt, extracted)
                else
                    std.ascii.eqlIgnoreCase(extracted, alt);

                if (display_match or extracted_match) {
                    matched = true;
                    if (!is_glob) {
                        if (std.mem.eql(u8, def.display_name, alt) or std.mem.eql(u8, extracted, alt)) {
                            matched_exact = true;
                        }
                    }
                    break; // one alternative matching is enough
                }
            }

            if (matched) {
                // Apply kind filter
                if (kind_filter) |kf| {
                    const k = scip.kindName(def.kind);
                    if (!std.ascii.eqlIgnoreCase(k, kf)) continue;
                }

                // Apply file filter
                if (file_filter) |ff| {
                    if (!fileMatchesSuffix(def.path, ff)) continue;
                }

                // Calculate relevance score
                var score: u8 = 0;

                if (matched_exact) {
                    score += 100;
                } else {
                    score += 80;
                }

                // Not in a test file
                if (!pathIsTest(def.path)) {
                    score += 50;
                }

                // Shorter paths (less nested) rank higher
                const path_depth = countPathSeparators(def.path);
                if (path_depth <= 2) score += 10;

                try matches.append(allocator, .{ .symbol = sym_name, .def = def, .score = score });
            }
        }

        // Sort by score descending
        sortMatchesByScore(&matches);
        return matches;
    }

    /// Check if a path appears to be a test file.
    fn pathIsTest(path: []const u8) bool {
        return std.mem.indexOf(u8, path, "test") != null or
            std.mem.indexOf(u8, path, "__tests__") != null or
            std.mem.indexOf(u8, path, "spec") != null or
            std.mem.endsWith(u8, path, ".test.js") or
            std.mem.endsWith(u8, path, ".test.ts") or
            std.mem.endsWith(u8, path, ".spec.js") or
            std.mem.endsWith(u8, path, ".spec.ts") or
            std.mem.endsWith(u8, path, "_test.go") or
            std.mem.endsWith(u8, path, "_test.py");
    }

    /// Count path separators to estimate nesting depth.
    fn countPathSeparators(path: []const u8) usize {
        var count: usize = 0;
        for (path) |c| {
            if (c == '/') count += 1;
        }
        return count;
    }

    /// Sort matches by score (descending), using insertion sort for small arrays.
    fn sortMatchesByScore(matches: *MatchList) void {
        if (matches.items.len <= 1) return;

        var i: usize = 1;
        while (i < matches.items.len) : (i += 1) {
            const key = matches.items[i];
            var j: usize = i;
            while (j > 0 and matches.items[j - 1].score < key.score) : (j -= 1) {
                matches.items[j] = matches.items[j - 1];
            }
            matches.items[j] = key;
        }
    }

    const MatchEntry = struct { symbol: []const u8, def: DefInfo, score: u8 = 0 };
    const MatchList = std.ArrayListUnmanaged(MatchEntry);

    /// Build a set of all symbol strings occurring in a file's document.
    /// Returns empty set if file is not in the index.
    fn buildFileOccurrenceSet(
        self: *const CodeIndex,
        allocator: std.mem.Allocator,
        file_path: []const u8,
    ) std.StringHashMapUnmanaged(void) {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return set;
        const doc = self.index.documents[doc_idx];
        for (doc.occurrences) |occ| {
            if (occ.symbol.len > 0) {
                set.put(allocator, occ.symbol, {}) catch {};
            }
        }
        return set;
    }

    /// Check if a symbol appears in a file's occurrences.
    fn isSymbolInFile(self: *const CodeIndex, file_path: []const u8, symbol: []const u8) bool {
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return false;
        const doc = self.index.documents[doc_idx];
        for (doc.occurrences) |occ| {
            if (std.mem.eql(u8, occ.symbol, symbol)) return true;
        }
        return false;
    }

    /// Find distinct symbol display names referenced within a line range of a file.
    /// Excludes the definition's own symbol. Returns non-external symbols only.
    fn findReferencesInRange(
        self: *const CodeIndex,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        own_symbol: []const u8,
        start_line: i32,
        end_line: i32,
    ) std.ArrayListUnmanaged([]const u8) {
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return result;
        const doc = self.index.documents[doc_idx];

        // Collect unique symbols in range
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);

        for (doc.occurrences) |occ| {
            if (occ.symbol.len == 0) continue;
            // Skip self
            if (std.mem.eql(u8, occ.symbol, own_symbol)) continue;
            // Must be within range
            if (occ.range.start_line < start_line or occ.range.start_line > end_line) continue;
            // Skip if already seen
            if (seen.contains(occ.symbol)) continue;
            seen.put(allocator, occ.symbol, {}) catch continue;

            // Look up def info — skip external symbols
            const def = self.symbol_to_defs.get(occ.symbol) orelse continue;
            if (def.path.len == 0) continue;

            // Use display_name if available, else extract from symbol string
            const name = if (def.display_name.len > 0) def.display_name else scip.extractSymbolName(occ.symbol);
            if (name.len > 0) {
                result.append(allocator, name) catch continue;
            }
        }
        return result;
    }

    /// Return a table of contents for a file: all definition symbols with name, kind, line, end_line.
    /// Excludes symbols listed in `exclude_symbols`. Results sorted by line number.
    const FileTOCEntry = struct {
        name: []const u8,
        kind: i32,
        line: i32,
        end_line: i32,
    };

    /// Returns true if a SCIP kind represents a top-level definition worth showing in a TOC.
    /// Filters out parameters, local variables, fields, and other noise.
    fn isTOCKind(kind: i32) bool {
        return switch (kind) {
            7, // class
            8, // constant
            9, // constructor
            11, // enum
            12, // enum_member
            17, // function
            21, // interface
            25, // macro
            26, // method
            29, // module
            49, // struct
            53, // trait
            54, // type
            55, // type_alias
            59, // union
            => true,
            else => false,
        };
    }

    fn getFileSymbolsTOC(
        self: *const CodeIndex,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        exclude_symbols: *const std.StringHashMapUnmanaged(void),
    ) std.ArrayListUnmanaged(FileTOCEntry) {
        var result: std.ArrayListUnmanaged(FileTOCEntry) = .empty;
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return result;
        const doc = self.index.documents[doc_idx];

        for (doc.symbols) |sym| {
            if (sym.symbol.len == 0) continue;
            if (!isTOCKind(sym.kind)) continue;
            if (exclude_symbols.contains(sym.symbol)) continue;

            const def = self.symbol_to_defs.get(sym.symbol) orelse continue;
            const name = if (sym.display_name.len > 0) sym.display_name else scip.extractSymbolName(sym.symbol);
            if (name.len == 0) continue;
            // Skip test functions — real symbol names never contain spaces
            if (std.mem.indexOfScalar(u8, name, ' ') != null) continue;

            result.append(allocator, .{
                .name = name,
                .kind = sym.kind,
                .line = def.line,
                .end_line = def.end_line,
            }) catch continue;
        }

        // Sort by line number
        const SortCtx = struct {
            fn lessThan(_: void, a: FileTOCEntry, b: FileTOCEntry) bool {
                return a.line < b.line;
            }
        };
        std.mem.sortUnstable(FileTOCEntry, result.items, {}, SortCtx.lessThan);

        return result;
    }

    fn getFileImports(self: *const CodeIndex, file_path: []const u8) ?FileImportList {
        return self.file_to_imports.get(file_path);
    }

    fn getChildren(self: *const CodeIndex, symbol: []const u8) ?RelationshipList {
        return self.parent_to_children.get(symbol);
    }

    fn getParent(self: *const CodeIndex, symbol: []const u8) ?[]const u8 {
        return self.symbol_to_parent.get(symbol);
    }

    fn getRelationships(self: *const CodeIndex, symbol: []const u8) ?RelationshipList {
        return self.symbol_to_relationships.get(symbol);
    }

    fn getReverseRelationships(self: *const CodeIndex, symbol: []const u8) ?RelationshipList {
        return self.symbol_to_reverse_relationships.get(symbol);
    }

    fn getCalls(self: *const CodeIndex, symbol: []const u8) ?RelationshipList {
        return self.symbol_to_calls.get(symbol);
    }

    fn getCallers(self: *const CodeIndex, symbol: []const u8) ?RelationshipList {
        return self.symbol_to_callers.get(symbol);
    }
};

// ── Batch Disambiguation ────────────────────────────────────────────────

const MAX_EXPLORE_QUERIES = 32;
const MAX_BODY_LINES: usize = 30;
const MAX_RELATED: usize = 5;
const MAX_TOTAL_BYTES: usize = 51200; // 50KB
const CONTEXT_BEFORE: usize = 3;
const MAX_TEXT_FIND_MATCHES: usize = 8;
const MAX_TEXT_REFS: usize = 20;
const MAX_TEXT_FILE_SYMBOLS: usize = 20;
const MAX_TEXT_NEARBY_SYMBOLS: usize = 5;
const MAX_TEXT_SNIPPET_BYTES: usize = 3000;

fn sameDirectory(path_a: []const u8, path_b: []const u8) bool {
    const dir_a = std.fs.path.dirname(path_a) orelse "";
    const dir_b = std.fs.path.dirname(path_b) orelse "";
    return std.mem.eql(u8, dir_a, dir_b);
}

/// Anchor info for disambiguation
const AnchorInfo = struct {
    query_idx: usize,
    match: CodeIndex.MatchEntry,
    file_symbols: std.StringHashMapUnmanaged(void),
};

/// Disambiguate a batch of symbol queries using anchor-driven coherence.
/// Returns an array of selected indices (one per query, null if no match).
fn disambiguateBatch(
    allocator: std.mem.Allocator,
    ci: *const CodeIndex,
    all_matches: []CodeIndex.MatchList,
) ![]?usize {
    const n = all_matches.len;
    const selected = try allocator.alloc(?usize, n);
    @memset(selected, null);

    // Phase 1: Classify anchors vs floaters
    var anchors: std.ArrayListUnmanaged(AnchorInfo) = .empty;
    defer {
        for (anchors.items) |*a| a.file_symbols.deinit(allocator);
        anchors.deinit(allocator);
    }
    var floater_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer floater_indices.deinit(allocator);

    for (all_matches, 0..) |matches, i| {
        if (matches.items.len == 0) {
            // No match — will produce error in output
            continue;
        } else if (matches.items.len == 1) {
            // Anchor: unambiguous
            selected[i] = 0;
            const anchor_match = matches.items[0];
            try anchors.append(allocator, .{
                .query_idx = i,
                .match = anchor_match,
                .file_symbols = ci.buildFileOccurrenceSet(allocator, anchor_match.def.path),
            });
        } else {
            // Floater: needs disambiguation
            try floater_indices.append(allocator, i);
        }
    }

    // Phase 2: If no floaters, all resolved
    if (floater_indices.items.len == 0) return selected;

    // Phase 3: Pair-Linking fallback if zero anchors
    if (anchors.items.len == 0) {
        // Find strongest pair across different query groups
        var best_score: i32 = -1;
        var best_qi: usize = 0;
        var best_ci_a: usize = 0;
        var best_qj: usize = 0;
        var best_ci_b: usize = 0;

        for (floater_indices.items, 0..) |fi, ii| {
            for (floater_indices.items[ii + 1 ..]) |fj| {
                for (all_matches[fi].items, 0..) |cand_a, ca| {
                    for (all_matches[fj].items, 0..) |cand_b, cb| {
                        var score: i32 = 0;
                        if (std.mem.eql(u8, cand_a.def.path, cand_b.def.path)) score += 50;
                        if (ci.isSymbolInFile(cand_a.def.path, cand_b.symbol)) score += 30;
                        if (ci.isSymbolInFile(cand_b.def.path, cand_a.symbol)) score += 30;
                        if (sameDirectory(cand_a.def.path, cand_b.def.path)) score += 10;
                        if (score > best_score) {
                            best_score = score;
                            best_qi = fi;
                            best_ci_a = ca;
                            best_qj = fj;
                            best_ci_b = cb;
                        }
                    }
                }
            }
        }

        if (best_score >= 0) {
            // Lock the pair as pseudo-anchors
            selected[best_qi] = best_ci_a;
            selected[best_qj] = best_ci_b;
            const match_a = all_matches[best_qi].items[best_ci_a];
            const match_b = all_matches[best_qj].items[best_ci_b];
            try anchors.append(allocator, .{
                .query_idx = best_qi,
                .match = match_a,
                .file_symbols = ci.buildFileOccurrenceSet(allocator, match_a.def.path),
            });
            try anchors.append(allocator, .{
                .query_idx = best_qj,
                .match = match_b,
                .file_symbols = ci.buildFileOccurrenceSet(allocator, match_b.def.path),
            });
        }
    }

    // Phase 4: Score remaining floaters against anchors
    for (floater_indices.items) |fi| {
        if (selected[fi] != null) continue; // already resolved by pair-linking

        var best_total: i32 = -1;
        var best_idx: usize = 0;

        for (all_matches[fi].items, 0..) |candidate, ci_idx| {
            var score: i32 = @intCast(candidate.score); // base score from findSymbol

            for (anchors.items) |anchor| {
                // Same file as anchor
                if (std.mem.eql(u8, candidate.def.path, anchor.match.def.path)) {
                    score += 50;
                }
                // Candidate's symbol in anchor's file occurrences
                if (anchor.file_symbols.contains(candidate.symbol)) {
                    score += 30;
                }
                // Anchor's symbol in candidate's file occurrences
                if (ci.isSymbolInFile(candidate.def.path, anchor.match.symbol)) {
                    score += 30;
                }
                // Same directory
                if (sameDirectory(candidate.def.path, anchor.match.def.path)) {
                    score += 10;
                }
            }

            if (score > best_total) {
                best_total = score;
                best_idx = ci_idx;
            }
        }

        selected[fi] = best_idx;
    }

    return selected;
}

/// Load and decode the SCIP index from .cog/index.scip.
fn loadIndex(allocator: std.mem.Allocator) !CodeIndex {
    const index_path = try getIndexPath(allocator);
    defer allocator.free(index_path);

    debug_log.log("loadIndex: opening {s}", .{index_path});
    const file = std.fs.openFileAbsolute(index_path, .{}) catch {
        printErr("error: no index found. Run " ++ dim ++ "cog code:index" ++ reset ++ " first.\n");
        return error.Explained;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch {
        printErr("error: failed to read index file\n");
        return error.Explained;
    };
    debug_log.log("loadIndex: read {d} bytes", .{data.len});

    const index = scip.decode(allocator, data) catch {
        allocator.free(data);
        printErr("error: failed to decode index file (corrupt or invalid format)\n");
        return error.Explained;
    };
    debug_log.log("loadIndex: decoded, {d} documents", .{index.documents.len});

    var ci = CodeIndex.build(allocator, index) catch {
        allocator.free(data);
        printErr("error: failed to build code index\n");
        return error.Explained;
    };
    ci.backing_data = data;
    return ci;
}

/// Load and decode the SCIP index for long-lived runtime use.
pub fn loadIndexForRuntime(allocator: std.mem.Allocator) !CodeIndex {
    return loadIndex(allocator);
}

pub const QueryIndexStatus = enum {
    ready,
    unavailable,
};

pub const IndexInfo = struct {
    file_size: u64,
    document_count: usize,
};

pub fn queryIndexStatusForRuntime(allocator: std.mem.Allocator) QueryIndexStatus {
    const info = queryIndexInfo(allocator);
    return if (info != null) .ready else .unavailable;
}

pub fn queryIndexInfo(allocator: std.mem.Allocator) ?IndexInfo {
    const index_path = getIndexPathQuiet(allocator) catch {
        debug_log.log("queryIndexInfo: missing .cog/index.scip", .{});
        return null;
    };
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch {
        debug_log.log("queryIndexInfo: index file not readable", .{});
        return null;
    };
    defer file.close();

    const stat = file.stat() catch {
        debug_log.log("queryIndexInfo: failed to stat index", .{});
        return null;
    };
    const file_size = stat.size;

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch {
        debug_log.log("queryIndexInfo: failed to read index", .{});
        return null;
    };
    defer allocator.free(data);

    var index = scip.decode(allocator, data) catch {
        debug_log.log("queryIndexInfo: failed to decode index", .{});
        return null;
    };

    // Count only project-local documents (exclude external/dependency files)
    var project_doc_count: usize = 0;
    for (index.documents) |doc| {
        const path = doc.relative_path;
        if (path.len == 0) continue;
        // Skip absolute paths (external dependencies)
        if (path[0] == '/') continue;
        // Skip paths reaching outside the project
        if (std.mem.startsWith(u8, path, "../") or std.mem.indexOf(u8, path, "/../") != null) continue;
        project_doc_count += 1;
    }
    scip.freeIndex(allocator, &index);

    debug_log.log("queryIndexInfo: {d} project documents ({d} total), {d} bytes", .{ project_doc_count, index.documents.len, file_size });
    return .{ .file_size = file_size, .document_count = project_doc_count };
}

// ── Commands ────────────────────────────────────────────────────────────

pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    debug_log.log("code_intel.dispatch: {s}", .{subcmd});
    if (std.mem.eql(u8, subcmd, "code:index")) return codeIndex(allocator, args);
    if (std.mem.eql(u8, subcmd, "code:sync")) return codeSync(allocator, args);

    if (std.mem.eql(u8, subcmd, "code:query") or
        std.mem.eql(u8, subcmd, "code:status") or
        std.mem.eql(u8, subcmd, "code:edit") or
        std.mem.eql(u8, subcmd, "code:create") or
        std.mem.eql(u8, subcmd, "code:delete") or
        std.mem.eql(u8, subcmd, "code:rename"))
    {
        printErr("error: '");
        printErr(subcmd);
        printErr("' has been removed from CLI. Use the MCP tools instead (code_query and code_explore).\n");
        printErr("Run " ++ dim ++ "cog mcp --help" ++ reset ++ " for MCP server usage.\n");
        return error.Explained;
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

// ── code:index ──────────────────────────────────────────────────────────

fn codeIndex(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    const index_start_ms = std.time.milliTimestamp();
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.code_index);
        return;
    }

    // Collect positional arguments (non-flag args) as patterns
    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    defer patterns.deinit(allocator);
    for (args) |arg| {
        const a: []const u8 = arg;
        if (!std.mem.startsWith(u8, a, "--")) {
            try patterns.append(allocator, a);
        }
    }

    // Load settings for default patterns and approved external roots.
    const settings_holder = settings_mod.Settings.load(allocator);
    defer if (settings_holder) |s| s.deinit(allocator);

    if (patterns.items.len == 0) {
        if (settings_holder) |s| {
            if (s.code) |code| {
                if (code.index) |index_patterns| {
                    for (index_patterns) |p| {
                        try patterns.append(allocator, p);
                    }
                }
            }
        }
    }

    if (patterns.items.len == 0) {
        const static_part = bold ++ "  cog code:index" ++ reset ++ " " ++ dim ++ "<pattern> [pattern...]" ++ reset ++ "\n" ++ "\n" ++ "  Specify one or more glob patterns to index.\n" ++ "  Patterns can also be configured in " ++ dim ++ ".cog/settings.json" ++ reset ++ ":\n" ++ dim ++ "    { \"code\": { \"index\": [\"**/*.ts\", \"**/*.go\"] } }" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n" ++ "    cog code:index \"**/*.ts\"       " ++ dim ++ "All .ts files recursively" ++ reset ++ "\n" ++ "    cog code:index \"src/**/*.go\"   " ++ dim ++ "All .go files under src/" ++ reset ++ "\n" ++ "    cog code:index src/main.zig   " ++ dim ++ "A single file" ++ reset ++ "\n" ++ "\n" ++ cyan ++ bold ++ "  Built-in" ++ reset ++ "\n" ++ comptime builtinExtensionList() ++ "\n";

        const installed_block = listInstalledBlock(allocator);
        defer if (installed_block) |b| allocator.free(b);

        tui.header();
        if (installed_block) |block| {
            const combined = std.fmt.allocPrint(allocator, "{s}{s}", .{ static_part, block }) catch {
                printErr(static_part);
                printErr(block);
                return error.Explained;
            };
            defer allocator.free(combined);
            printErr(combined);
        } else {
            printErr(static_part);
        }

        return error.Explained;
    }

    const cog_dir = paths.findOrCreateCogDir(allocator) catch {
        printErr("error: failed to create .cog directory\n");
        return error.Explained;
    };
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    // Create .cog directory if needed
    std.fs.makeDirAbsolute(cog_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("error: failed to create .cog directory\n");
            return error.Explained;
        },
    };

    // Load existing index (or start empty)
    // Track backing data buffers — protobuf decoder is zero-copy so string
    // slices point into these buffers. They must outlive the index.
    var backing_buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (backing_buffers.items) |buf| allocator.free(buf);
        backing_buffers.deinit(allocator);
    }

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    if (loaded.backing_data) |data| {
        backing_buffers.append(allocator, data) catch {};
    }

    const project_root = std.fs.path.dirname(cog_dir) orelse {
        printErr("error: failed to resolve project root\n");
        return error.Explained;
    };
    const external_roots = if (settings_holder) |s|
        if (s.code) |code| code.external_roots orelse &.{} else &.{}
    else
        &.{};

    // Expand all patterns with the shared path traversal policy.
    var files: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (files.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        files.deinit(allocator);
    }
    try collectMatchedFiles(allocator, project_root, patterns.items, external_roots, &files);

    if (files.items.len == 0) {
        printErr("error: no files matched\n");
        return error.Explained;
    }
    debug_log.log("codeIndex: start patterns={d} matched_files={d}", .{ patterns.items.len, files.items.len });
    debug_log.logResourceUsage("codeIndex:start");

    // TTY progress display — show header immediately so the user sees output
    const show_progress = tui.isStderrTty();
    const total_files = files.items.len;
    if (show_progress) {
        tui.header();
        tui.progressStart(total_files);
    }

    var indexed_count: usize = 0;
    var total_symbols: usize = 0;

    // Use an ArrayList for documents to avoid O(n²) reallocation.
    // mergeDocument grows by 1 each time — with 1000+ files that's
    // ~500K copies and as many intermediate allocations freed.
    var doc_list: std.ArrayListUnmanaged(scip.Document) = .empty;
    defer {
        for (doc_list.items) |*doc| scip.freeDocument(allocator, doc);
        doc_list.deinit(allocator);
    }
    try doc_list.ensureTotalCapacity(allocator, master_index.documents.len + files.items.len);
    doc_list.appendSliceAssumeCapacity(master_index.documents);
    // master_index.documents was decoded from protobuf (or empty); the individual
    // doc internals are now owned by doc_list. Free just the documents slice itself.
    if (master_index.documents.len > 0) allocator.free(master_index.documents);
    master_index.documents = &.{};

    var external_symbol_list: std.ArrayListUnmanaged(scip.SymbolInformation) = .empty;
    defer {
        for (external_symbol_list.items) |*sym| freeSymbolInformation(allocator, sym);
        external_symbol_list.deinit(allocator);
    }
    try external_symbol_list.ensureTotalCapacity(allocator, master_index.external_symbols.len);
    external_symbol_list.appendSliceAssumeCapacity(master_index.external_symbols);
    if (master_index.external_symbols.len > 0) allocator.free(master_index.external_symbols);
    master_index.external_symbols = &.{};

    // Tree-sitter per-file indexing
    var indexer = tree_sitter_indexer.Indexer.init();
    defer indexer.deinit();

    // Track extensions that need external indexers (not supported by tree-sitter)
    var seen_names: [16][]const u8 = undefined;
    var unique_exts: [16]extensions.Extension = undefined;
    var ext_files: [16]std.ArrayListUnmanaged([]const u8) = [_]std.ArrayListUnmanaged([]const u8){.empty} ** 16;
    var num_unique: usize = 0;
    defer {
        for (0..num_unique) |ext_idx| {
            ext_files[ext_idx].deinit(allocator);
        }
    }

    // Cache extension resolution by file extension to avoid re-reading
    // manifests from disk for every file (1000+ files = 1000+ JSON parses).
    var ext_cache_keys: [32][]const u8 = undefined;
    var ext_cache_vals: [32]?extensions.Extension = undefined;
    var ext_cache_installed: [32]bool = [_]bool{false} ** 32;
    var ext_cache_len: usize = 0;
    defer for (0..ext_cache_len) |ci| {
        if (ext_cache_installed[ci]) {
            if (ext_cache_vals[ci]) |*val| extensions.freeExtension(allocator, val);
        }
    };

    for (files.items) |matched_file| {
        const file_path = matched_file.logical_path;
        const physical_path = matched_file.physical_path;
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) continue;

        // Resolve extension with cache — avoids re-reading manifests from disk
        const resolved = blk: {
            for (ext_cache_keys[0..ext_cache_len], ext_cache_vals[0..ext_cache_len]) |key, val| {
                if (std.mem.eql(u8, key, ext)) break :blk val;
            }
            // Cache miss — resolve and store
            const r = extensions.resolveByExtension(allocator, ext);
            if (ext_cache_len < 32) {
                ext_cache_keys[ext_cache_len] = ext;
                ext_cache_vals[ext_cache_len] = r;
                ext_cache_installed[ext_cache_len] = if (r) |v| v.installed else false;
                ext_cache_len += 1;
            }
            break :blk r;
        } orelse continue;

        const idx = resolved.indexer orelse continue;

        switch (idx) {
            .tree_sitter => |ts_config| {
                const file_start_ms = std.time.milliTimestamp();
                if (show_progress) {
                    tui.progressUpdate(indexed_count, total_files, total_symbols, file_path);
                }

                // Read source file
                debug_log.log("codeIndex: tree_sitter:file_start path={s} grammar={s}", .{ file_path, ts_config.grammar_name });
                const source = readFileContents(allocator, physical_path) orelse continue;
                defer allocator.free(source);
                debug_log.log("codeIndex: tree_sitter:file_read path={s} bytes={d} elapsed_ms={d}", .{ file_path, source.len, std.time.milliTimestamp() - file_start_ms });
                debug_log.logResourceUsage("codeIndex:tree_sitter:file_read");

                // Index with tree-sitter
                if (indexer.indexFile(allocator, source, file_path, ts_config)) |result| {
                    backing_buffers.append(allocator, result.string_data) catch {};
                    mergeDocumentList(allocator, &doc_list, result.doc);
                    indexed_count += 1;
                    total_symbols += result.doc.symbols.len;
                    debug_log.log(
                        "codeIndex: tree_sitter:file_done path={s} symbols={d} occurrences={d} elapsed_ms={d}",
                        .{ file_path, result.doc.symbols.len, result.doc.occurrences.len, std.time.milliTimestamp() - file_start_ms },
                    );
                } else |_| {
                    // Indexing failed (e.g. Flow-typed JS parsed as plain JS).
                    // Still add a stub document so the file appears in the index
                    // and queries report "no symbols" instead of "file not found".
                    mergeDocumentList(allocator, &doc_list, .{
                        .language = ts_config.scip_name,
                        .relative_path = file_path,
                        .occurrences = &.{},
                        .symbols = &.{},
                    });
                    indexed_count += 1;
                    debug_log.log("codeIndex: tree_sitter:file_failed path={s} elapsed_ms={d}", .{ file_path, std.time.milliTimestamp() - file_start_ms });
                }
                debug_log.logResourceUsage("codeIndex:tree_sitter:file_done");

                if (show_progress) {
                    tui.progressUpdate(indexed_count, total_files, total_symbols, file_path);
                }
            },
            .scip_binary => {
                // Collect for batch external indexing
                var found = false;
                var found_idx: usize = 0;
                for (seen_names[0..num_unique], 0..) |name, i| {
                    if (std.mem.eql(u8, name, resolved.name)) {
                        found = true;
                        found_idx = i;
                        break;
                    }
                }
                if (!found and num_unique < 16) {
                    seen_names[num_unique] = resolved.name;
                    unique_exts[num_unique] = resolved;
                    ext_files[num_unique].append(allocator, physical_path) catch {};
                    num_unique += 1;
                } else if (found) {
                    ext_files[found_idx].append(allocator, physical_path) catch {};
                }
            },
        }
    }

    // Invoke external indexers in bulk for unsupported languages.
    for (0..num_unique) |ext_idx| {
        const scip_config = switch (unique_exts[ext_idx].indexer orelse continue) {
            .scip_binary => |sc| sc,
            .tree_sitter => continue,
        };
        const batch_files = ext_files[ext_idx].items;
        if (batch_files.len == 0) continue;
        const progress_path = batch_files[batch_files.len - 1];
        if (show_progress) {
            tui.progressUpdate(indexed_count, total_files, total_symbols, progress_path);
        }

        debug_log.log("codeIndex: invoking bulk external indexer {s} for {d} files", .{ scip_config.command, batch_files.len });
        debug_log.logResourceUsage("codeIndex:external:start");
        const batch_start_count = indexed_count;
        var progress_ctx = ExternalIndexerProgress{
            .indexed_count = &indexed_count,
            .total_files = total_files,
            .total_symbols = &total_symbols,
            .show_progress = show_progress,
        };
        const result = invokeIndexerForFileList(allocator, batch_files, scip_config, &progress_ctx) catch |err| {
            debug_log.log("codeIndex: external_failed command={s} files={d} err={s}", .{ scip_config.command, batch_files.len, @errorName(err) });
            return err;
        };

        backing_buffers.append(allocator, result.backing_data.?) catch {};
        for (result.index.documents) |doc| {
            mergeDocumentList(allocator, &doc_list, doc);
            total_symbols += doc.symbols.len;
        }
        allocator.free(result.index.documents);
        for (result.index.external_symbols) |sym| {
            mergeExternalSymbolList(allocator, &external_symbol_list, sym);
        }
        allocator.free(result.index.external_symbols);
        if (indexed_count == batch_start_count) indexed_count += batch_files.len;
        debug_log.log(
            "codeIndex: external_done command={s} files={d} docs={d} external_symbols={d}",
            .{ scip_config.command, batch_files.len, result.index.documents.len, result.index.external_symbols.len },
        );
        debug_log.logResourceUsage("codeIndex:external:done");

        if (show_progress) {
            tui.progressUpdate(indexed_count, total_files, total_symbols, progress_path);
        }
    }

    // Transfer documents back to master_index for encoding/freeing
    master_index.documents = try doc_list.toOwnedSlice(allocator);
    master_index.external_symbols = try external_symbol_list.toOwnedSlice(allocator);
    // doc_list is now empty; its defer is a no-op

    // Encode and write the master index
    const encoded = scip_encode.encodeIndex(allocator, master_index) catch {
        printErr("error: failed to encode index\n");
        return error.Explained;
    };
    defer allocator.free(encoded);

    const lock_fd = acquireIndexLock(allocator, cog_dir) orelse {
        printErr("error: failed to lock index file\n");
        return error.Explained;
    };
    defer releaseIndexLock(lock_fd);
    debug_log.log("codeIndex: atomically replacing index bytes={d}", .{encoded.len});
    if (!writeEncodedIndexAtomically(allocator, index_path, encoded)) {
        printErr("error: failed to write index file\n");
        return error.Explained;
    }
    writeManifestForIndex(allocator, index_path, master_index.documents, .{});

    // Add external symbols to total count
    total_symbols += master_index.external_symbols.len;

    if (show_progress) {
        const skipped = files.items.len - indexed_count;
        tui.progressFinish(indexed_count, total_symbols, skipped, index_path);
    }
    debug_log.log(
        "codeIndex: done indexed={d} total_symbols={d} elapsed_ms={d}",
        .{ indexed_count, total_symbols, std.time.milliTimestamp() - index_start_ms },
    );
    debug_log.logResourceUsage("codeIndex:done");
}

/// Result from loading/decoding a SCIP index.
/// The backing_data buffer must stay alive as long as the index is used,
/// because the protobuf decoder is zero-copy (string slices point into it).
const IndexResult = struct {
    index: scip.Index,
    backing_data: ?[]const u8,
};

/// Load existing SCIP index or return an empty one.
/// Caller must free backing_data after the index is no longer needed.
fn loadExistingIndex(allocator: std.mem.Allocator, index_path: []const u8) IndexResult {
    debug_log.log("loadExistingIndex: opening {s}", .{index_path});
    const file = std.fs.openFileAbsolute(index_path, .{}) catch |err| {
        debug_log.log("loadExistingIndex: open failed error={s}; using empty index", .{@errorName(err)});
        return .{ .index = emptyIndex(), .backing_data = null };
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch |err| {
        debug_log.log("loadExistingIndex: read failed error={s}; using empty index", .{@errorName(err)});
        return .{ .index = emptyIndex(), .backing_data = null };
    };
    debug_log.log("loadExistingIndex: read bytes={d}", .{data.len});

    const index = scip.decode(allocator, data) catch {
        allocator.free(data);
        return .{ .index = emptyIndex(), .backing_data = null };
    };

    return .{ .index = index, .backing_data = data };
}

fn emptyIndex() scip.Index {
    return .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "cog", .version = "1.0" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &.{},
        .external_symbols = &.{},
    };
}

fn freeSymbolInformation(allocator: std.mem.Allocator, sym: *scip.SymbolInformation) void {
    allocator.free(sym.documentation);
    allocator.free(sym.relationships);
}

/// Read a file's contents. Returns null on failure.
fn readFileContents(allocator: std.mem.Allocator, file_path: []const u8) ?[]const u8 {
    debug_log.log("readFileContents: opening {s}", .{file_path});
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        debug_log.log("readFileContents: open failed path={s} error={s}", .{ file_path, @errorName(err) });
        return null;
    };
    defer file.close();
    const data = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch |err| {
        debug_log.log("readFileContents: read failed path={s} error={s}", .{ file_path, @errorName(err) });
        return null;
    };
    debug_log.log("readFileContents: read path={s} bytes={d}", .{ file_path, data.len });
    return data;
}

/// Recursively collect files from a directory.
fn collectFiles(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden dirs and common non-source dirs
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;

        const child_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            try collectFiles(allocator, child_path, out);
            allocator.free(child_path);
        } else if (entry.kind == .file) {
            try out.append(allocator, child_path);
        } else {
            allocator.free(child_path);
        }
    }
}

/// Match a path against a glob pattern using the shared scan/watch semantics.
pub const globMatch = path_matcher.globMatch;

/// Extract the literal directory prefix from a glob pattern (everything before the first wildcard).
/// Returns "." if the pattern starts with a wildcard.
fn globPrefix(pattern: []const u8) []const u8 {
    // Find the first wildcard character
    var first_wild: usize = pattern.len;
    for (pattern, 0..) |c, i| {
        if (c == '*' or c == '?') {
            first_wild = i;
            break;
        }
    }

    if (first_wild == 0) return ".";

    // Walk back to the last `/` before the wildcard
    var last_slash: usize = 0;
    var found_slash = false;
    for (pattern[0..first_wild], 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found_slash = true;
        }
    }

    if (!found_slash) return ".";
    return pattern[0..last_slash];
}

/// Returns true if the string contains glob wildcard characters (* or ?).
fn hasGlobChars(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?') return true;
    }
    return false;
}

/// Split a name pattern on '|' for alternation support.
/// Returns a bounded array of slices into the original string.
/// Example: "banner|header|splash" → {"banner", "header", "splash"}
/// If there is no '|', returns a single-element array with the original string.
const Alternatives = struct {
    buf: [max_alternatives][]const u8 = undefined,
    len: usize = 0,
    const max_alternatives = 16;

    fn items(self: *const Alternatives) []const []const u8 {
        return self.buf[0..self.len];
    }
};

fn splitAlternatives(name: []const u8) Alternatives {
    var result: Alternatives = .{};
    var start: usize = 0;
    for (name, 0..) |c, i| {
        if (c == '|') {
            if (i > start) {
                if (result.len < Alternatives.max_alternatives) {
                    result.buf[result.len] = name[start..i];
                    result.len += 1;
                }
            }
            start = i + 1;
        }
    }
    // Last segment (or only segment if no '|')
    if (start < name.len) {
        if (result.len < Alternatives.max_alternatives) {
            result.buf[result.len] = name[start..];
            result.len += 1;
        }
    }
    return result;
}

/// Case-insensitive glob match for symbol names.
/// Supports `*` (zero or more chars) and `?` (one char).
/// Unlike `globMatch`, this has no path separator semantics — `*` matches any character.
fn nameGlobMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0; // pattern index
    var ni: usize = 0; // name index
    var star_pi: usize = 0;
    var star_ni: usize = 0;
    var has_star = false;

    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_ni = ni;
                has_star = true;
                pi += 1;
                continue;
            }
            if (ni < name.len) {
                if (pattern[pi] == '?' or std.ascii.toLower(pattern[pi]) == std.ascii.toLower(name[ni])) {
                    pi += 1;
                    ni += 1;
                    continue;
                }
            }
        }
        if (has_star and star_ni < name.len) {
            star_ni += 1;
            ni = star_ni;
            pi = star_pi + 1;
            continue;
        }
        return false;
    }
    return true;
}

/// Check if a file path matches a suffix filter.
/// Handles absolute vs relative path differences by trying exact match,
/// then endsWith in both directions.
fn fileMatchesSuffix(indexed_path: []const u8, filter: []const u8) bool {
    if (std.mem.eql(u8, indexed_path, filter)) return true;
    if (std.mem.endsWith(u8, filter, indexed_path)) return true;
    if (std.mem.endsWith(u8, indexed_path, filter)) return true;
    return false;
}

/// Collect files matching a glob pattern.
/// Extracts the literal prefix directory, walks it recursively, and filters
/// each file path against the full glob pattern using `globMatch`.
pub fn collectGlobFiles(allocator: std.mem.Allocator, pattern: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const prefix = globPrefix(pattern);

    // Check if the pattern is a literal file path (no wildcards at all)
    const has_wildcard = for (pattern) |c| {
        if (c == '*' or c == '?') break true;
    } else false;

    if (!has_wildcard) {
        // Literal path — check if it's a file or directory
        const stat = std.fs.cwd().statFile(pattern) catch return;
        if (stat.kind == .file) {
            try out.append(allocator, try allocator.dupe(u8, pattern));
        } else if (stat.kind == .directory) {
            // Literal directory — collect all files recursively
            try collectFiles(allocator, pattern, out);
        }
        return;
    }

    // Walk the prefix directory and match against the pattern
    try collectGlobFilesRecursive(allocator, prefix, pattern, out);
}

fn isNegativeGlobPattern(pattern: []const u8) bool {
    return pattern.len > 1 and pattern[0] == '!';
}

fn normalizeGlobPattern(pattern: []const u8) []const u8 {
    return if (isNegativeGlobPattern(pattern)) pattern[1..] else pattern;
}

fn collectMatchedFiles(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    patterns: []const []const u8,
    external_roots: []const []const u8,
    out: *std.ArrayListUnmanaged(path_matcher.MatchedPath),
) !void {
    var matcher = try path_matcher.PathMatcher.init(allocator, .{
        .project_root = project_root,
        .patterns = patterns,
        .external_roots = external_roots,
    });
    defer matcher.deinit();
    try matcher.collect(out);
}

fn collectConfiguredFiles(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    patterns: []const []const u8,
    external_roots: []const []const u8,
    out: *std.ArrayListUnmanaged(path_matcher.MatchedPath),
) !void {
    debug_log.log(
        "collectConfiguredFiles: project={s} patterns={d} external_roots={d}",
        .{ project_root, patterns.len, external_roots.len },
    );
    try collectMatchedFiles(allocator, project_root, patterns, external_roots, out);
    debug_log.log("collectConfiguredFiles: matched={d}", .{out.items.len});
}

/// Recursively walk a directory, building relative paths and matching against a glob pattern.
fn collectGlobFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden dirs and common non-source dirs
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;

        const child_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        // Resolve symlinks to their target kind
        const kind = if (entry.kind == .sym_link) blk: {
            const stat = dir.statFile(entry.name) catch break :blk entry.kind;
            break :blk if (stat.kind == .directory) std.fs.Dir.Entry.Kind.directory else if (stat.kind == .file) std.fs.Dir.Entry.Kind.file else entry.kind;
        } else entry.kind;

        if (kind == .directory) {
            try collectGlobFilesRecursive(allocator, child_path, pattern, out);
            allocator.free(child_path);
        } else if (kind == .file) {
            if (globMatch(pattern, child_path)) {
                try out.append(allocator, child_path);
            } else {
                allocator.free(child_path);
            }
        } else {
            allocator.free(child_path);
        }
    }
}

/// Result from invoking a per-file indexer.
const DocumentResult = struct {
    doc: scip.Document,
    backing_data: []const u8,
};

fn invokeIndexerWithSubstitutions(
    allocator: std.mem.Allocator,
    config: extensions.ScipBinaryConfig,
    extra_subs: []const settings_mod.Substitution,
    file_paths: ?[]const []const u8,
    progress: ?*ExternalIndexerProgress,
) !IndexResult {
    const temp_dir_path = try paths.getProjectTempDir(allocator);
    defer allocator.free(temp_dir_path);
    var temp_dir = try std.fs.openDirAbsolute(temp_dir_path, .{ .no_follow = true });
    defer temp_dir.close();

    const temp = try fs_util.createSecureTempFile(temp_dir, allocator, "index-scip");
    defer allocator.free(temp.name);
    var temp_file = temp.file;
    defer temp_file.close();
    defer temp_dir.deleteFile(temp.name) catch |err| {
        debug_log.log("invokeIndexerWithSubstitutions: failed to remove temporary SCIP output {s}: {s}", .{ temp.name, @errorName(err) });
    };
    const tmp_path = try std.fs.path.join(allocator, &.{ temp_dir_path, temp.name });
    defer allocator.free(tmp_path);
    debug_log.log("invokeIndexerWithSubstitutions: reserved private SCIP output {s}", .{tmp_path});

    const subs = try allocator.alloc(settings_mod.Substitution, extra_subs.len + 1);
    defer allocator.free(subs);
    @memcpy(subs[0..extra_subs.len], extra_subs);
    subs[extra_subs.len] = .{ .key = "{output}", .value = tmp_path };

    var expanded_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (expanded_args.items) |arg| allocator.free(arg);
        expanded_args.deinit(allocator);
    }

    for (config.args) |arg| {
        if (std.mem.eql(u8, arg, "{files}")) {
            const files = file_paths orelse return error.SubstitutionFailed;
            for (files) |file_path| {
                try expanded_args.append(allocator, try allocator.dupe(u8, file_path));
            }
            continue;
        }

        var current: []const u8 = try allocator.dupe(u8, arg);
        errdefer allocator.free(current);
        for (subs) |sub| {
            const next = settings_mod.substitutePlaceholder(allocator, current, sub.key, sub.value) catch {
                allocator.free(current);
                return error.SubstitutionFailed;
            };
            allocator.free(current);
            current = next;
        }
        try expanded_args.append(allocator, current);
    }

    const full_args = try allocator.alloc([]const u8, 1 + expanded_args.items.len);
    defer allocator.free(full_args);
    full_args[0] = config.command;
    @memcpy(full_args[1..], expanded_args.items);

    debug_log.log("invokeIndexerWithSubstitutions: spawning {s} with {d} args", .{ config.command, expanded_args.items.len });
    var child = std.process.Child.init(full_args, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.spawn() catch |err| {
        debug_log.log("invokeIndexerWithSubstitutions: spawn failed for {s}: {s}", .{ config.command, @errorName(err) });
        return err;
    };

    if (child.stderr) |stderr_file| {
        consumeIndexerProgress(allocator, stderr_file, progress) catch |err| {
            debug_log.log("invokeIndexerWithSubstitutions: stderr progress read failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    const term = child.wait() catch |err| {
        debug_log.log("invokeIndexerWithSubstitutions: wait failed for {s}: {s}", .{ config.command, @errorName(err) });
        return err;
    };
    try ensureIndexerTermSucceeded(term);

    debug_log.log("invokeIndexerWithSubstitutions: reading reserved output {s}", .{tmp_path});
    try temp_file.seekTo(0);
    const tmp_data = try temp_file.readToEndAlloc(allocator, 256 * 1024 * 1024);

    const index = scip.decode(allocator, tmp_data) catch |err| {
        allocator.free(tmp_data);
        return err;
    };
    if (index.documents.len == 0 and index.external_symbols.len == 0) {
        var empty_index = index;
        scip.freeIndex(allocator, &empty_index);
        allocator.free(tmp_data);
        return error.NoDocuments;
    }

    return .{ .index = index, .backing_data = tmp_data };
}

fn ensureIndexerTermSucceeded(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0) return error.IndexerFailed,
        .Signal => |sig| {
            debug_log.log("invokeIndexerWithSubstitutions: indexer terminated by signal {d}", .{sig});
            return error.IndexerFailed;
        },
        else => return error.IndexerFailed,
    }
}

fn consumeIndexerProgress(
    allocator: std.mem.Allocator,
    stderr_file: std.fs.File,
    progress: ?*ExternalIndexerProgress,
) !void {
    var read_buf: [4096]u8 = undefined;
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(allocator);

    while (true) {
        const n = try stderr_file.read(&read_buf);
        if (n == 0) break;
        try pending.appendSlice(allocator, read_buf[0..n]);

        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |idx| {
            const line = pending.items[0..idx];
            try handleIndexerProgressLine(allocator, line, progress);
            std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - (idx + 1)], pending.items[idx + 1 ..]);
            pending.items.len -= idx + 1;
        }
    }

    if (pending.items.len > 0) {
        try handleIndexerProgressLine(allocator, pending.items, progress);
    }
}

fn handleIndexerProgressLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    progress: ?*ExternalIndexerProgress,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;

    switch (try parseIndexerProgressEvent(allocator, trimmed)) {
        .ignore => debug_log.log("extension stderr: {s}", .{trimmed}),
        .file_done => |file_path| {
            defer allocator.free(file_path);
            if (progress) |ctx| ctx.fileDone(file_path);
        },
        .file_error => |file_path| {
            defer allocator.free(file_path);
            if (progress) |ctx| ctx.fileDone(file_path);
        },
        .phase => |phase| {
            defer allocator.free(phase.phase);
            if (phase.path) |path| {
                defer allocator.free(path);
            }
            if (progress) |ctx| ctx.phaseUpdate(phase.phase, phase.path);
        },
    }
}

fn parseIndexerProgressEvent(allocator: std.mem.Allocator, line: []const u8) !ProgressEvent {
    const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
        debug_log.log("parseIndexerProgressEvent: ignoring non-json line", .{});
        return .ignore;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return .ignore;
    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return .ignore;
    const event_val = obj.get("event") orelse return .ignore;
    if (type_val != .string or event_val != .string) return .ignore;
    if (!std.mem.eql(u8, type_val.string, "progress")) return .ignore;

    if (std.mem.eql(u8, event_val.string, "file_done") or std.mem.eql(u8, event_val.string, "file_error")) {
        const path_val = obj.get("path") orelse return .ignore;
        if (path_val != .string) return .ignore;
        const path_copy = try allocator.dupe(u8, path_val.string);
        if (std.mem.eql(u8, event_val.string, "file_done")) {
            return .{ .file_done = path_copy };
        }
        return .{ .file_error = path_copy };
    }

    if (std.mem.eql(u8, event_val.string, "phase")) {
        const phase_val = obj.get("phase") orelse return .ignore;
        if (phase_val != .string) return .ignore;
        const phase_copy = try allocator.dupe(u8, phase_val.string);
        errdefer allocator.free(phase_copy);
        var path_copy: ?[]const u8 = null;
        if (obj.get("path")) |path_val| {
            if (path_val != .string) return .ignore;
            path_copy = try allocator.dupe(u8, path_val.string);
        }
        return .{ .phase = .{ .phase = phase_copy, .path = path_copy } };
    }

    return .ignore;
}

/// Invoke an indexer for a single file, decode the SCIP output, return the document.
/// Caller must free backing_data after the document is no longer needed.
fn invokeIndexerForFile(allocator: std.mem.Allocator, file_path: []const u8, config: extensions.ScipBinaryConfig) !DocumentResult {
    const one_file = [_][]const u8{file_path};
    const tmp_result = try invokeIndexerForFileList(allocator, &one_file, config, null);
    var tmp_index = tmp_result.index;
    const tmp_data = tmp_result.backing_data orelse unreachable;

    if (tmp_index.documents.len == 0) {
        scip.freeIndex(allocator, &tmp_index);
        allocator.free(tmp_data);
        return error.NoDocuments;
    }

    var picked_idx: usize = 0;
    for (tmp_index.documents, 0..) |doc, i| {
        if (std.mem.eql(u8, doc.relative_path, file_path)) {
            picked_idx = i;
            break;
        }
    }

    // Free everything except the first document (which we return)
    for (tmp_index.documents, 0..) |*doc, i| {
        if (i == picked_idx) continue;
        scip.freeDocument(allocator, doc);
    }
    for (tmp_index.external_symbols) |*sym| {
        freeSymbolInformation(allocator, sym);
    }
    allocator.free(tmp_index.external_symbols);

    // Take ownership of the selected document
    const doc = tmp_index.documents[picked_idx];
    allocator.free(tmp_index.documents);

    return .{
        .doc = .{
            .language = doc.language,
            .relative_path = file_path,
            .occurrences = doc.occurrences,
            .symbols = doc.symbols,
        },
        .backing_data = tmp_data,
    };
}

fn invokeIndexerForFileList(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    config: extensions.ScipBinaryConfig,
    progress: ?*ExternalIndexerProgress,
) !IndexResult {
    return invokeIndexerWithSubstitutions(allocator, config, &.{}, file_paths, progress);
}

/// Invoke an indexer for a project directory, decode the SCIP output, return the full index.
/// Caller must free backing_data after the index is no longer needed.
fn invokeProjectIndexer(allocator: std.mem.Allocator, target_path: []const u8, config: extensions.ScipBinaryConfig) !IndexResult {
    const subs: []const settings_mod.Substitution = &.{
        .{ .key = "{file}", .value = target_path },
    };
    return invokeIndexerWithSubstitutions(allocator, config, subs, null, null);
}

/// Merge a document into the master index (replace existing or append).
/// Merge a document into an ArrayList (amortized O(1) append).
/// Used by bulk indexing paths to avoid O(n²) reallocation.
fn mergeDocumentList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(scip.Document), new_doc: scip.Document) void {
    for (list.items, 0..) |*doc, i| {
        if (std.mem.eql(u8, doc.relative_path, new_doc.relative_path)) {
            scip.freeDocument(allocator, doc);
            list.items[i] = new_doc;
            return;
        }
    }
    list.append(allocator, new_doc) catch {};
}

fn mergeExternalSymbolList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(scip.SymbolInformation),
    new_sym: scip.SymbolInformation,
) void {
    for (list.items, 0..) |*sym, i| {
        if (std.mem.eql(u8, sym.symbol, new_sym.symbol)) {
            freeSymbolInformation(allocator, sym);
            list.items[i] = new_sym;
            return;
        }
    }
    list.append(allocator, new_sym) catch {};
}

/// Merge a document into the master index (replace existing or append).
/// Used by single-file update paths (watcher, manual re-index).
fn mergeDocument(allocator: std.mem.Allocator, index: *scip.Index, new_doc: scip.Document) void {
    // Look for existing document with same relative_path
    for (index.documents, 0..) |*doc, i| {
        if (std.mem.eql(u8, doc.relative_path, new_doc.relative_path)) {
            // Replace: free old internals, put new doc in place
            scip.freeDocument(allocator, doc);
            index.documents[i] = new_doc;
            return;
        }
    }

    // Not found — grow documents slice and append
    const old_len = index.documents.len;
    const new_docs = allocator.alloc(scip.Document, old_len + 1) catch return;
    @memcpy(new_docs[0..old_len], index.documents);
    new_docs[old_len] = new_doc;
    if (old_len > 0) allocator.free(index.documents);
    index.documents = new_docs;
}

/// Remove a document from the index by relative_path.
fn removeDocument(allocator: std.mem.Allocator, index: *scip.Index, rel_path: []const u8) void {
    for (index.documents, 0..) |*doc, i| {
        if (!std.mem.eql(u8, doc.relative_path, rel_path)) continue;

        const old_documents = index.documents;
        const new_len = old_documents.len - 1;
        if (new_len == 0) {
            scip.freeDocument(allocator, doc);
            allocator.free(old_documents);
            index.documents = &.{};
            return;
        }

        const new_documents = allocator.alloc(scip.Document, new_len) catch {
            debug_log.log("removeDocument: allocation failed path={s}; preserving index", .{rel_path});
            return;
        };
        @memcpy(new_documents[0..i], old_documents[0..i]);
        @memcpy(new_documents[i..], old_documents[i + 1 ..]);
        scip.freeDocument(allocator, doc);
        allocator.free(old_documents);
        index.documents = new_documents;
        return;
    }
}

const ReindexPath = struct {
    logical_path: []const u8,
    physical_path: ?[]const u8,
};

const ExternalReindexPath = struct {
    logical_path: []const u8,
    physical_path: []const u8,
};

fn findPhysicalPath(matched_files: []const path_matcher.MatchedPath, logical_path: []const u8) ?[]const u8 {
    for (matched_files) |file| {
        if (std.mem.eql(u8, file.logical_path, logical_path)) return file.physical_path;
    }
    return null;
}

/// Deep-copy the arrays a document owns so an extra alias can hold its own.
///
/// Strings stay borrowed from the indexer's backing buffer — only the arrays
/// `scip.freeDocument` releases are duplicated.
fn dupeDocumentBody(allocator: std.mem.Allocator, doc: scip.Document) !scip.Document {
    const occurrences = try allocator.dupe(scip.Occurrence, doc.occurrences);
    errdefer allocator.free(occurrences);

    const symbols = try allocator.alloc(scip.SymbolInformation, doc.symbols.len);
    var initialized: usize = 0;
    errdefer {
        for (symbols[0..initialized]) |*sym| freeSymbolInformation(allocator, sym);
        allocator.free(symbols);
    }

    for (doc.symbols, 0..) |sym, i| {
        const documentation = try allocator.dupe([]const u8, sym.documentation);
        errdefer allocator.free(documentation);
        const relationships = try allocator.dupe(scip.Relationship, sym.relationships);
        symbols[i] = .{
            .symbol = sym.symbol,
            .documentation = documentation,
            .relationships = relationships,
            .kind = sym.kind,
            .display_name = sym.display_name,
            .enclosing_symbol = sym.enclosing_symbol,
        };
        initialized = i + 1;
    }

    return .{
        .language = doc.language,
        .relative_path = doc.relative_path,
        .occurrences = occurrences,
        .symbols = symbols,
    };
}

/// Rewrite external indexer documents onto every logical alias configured for
/// the physical path the indexer echoed back.
///
/// External indexers are handed physical paths and report those same paths in
/// `relative_path`, but the master index is keyed by logical path — the
/// convention tree-sitter documents already follow. A single physical source
/// can be reachable under several logical names (a symlink alias, an
/// `@external/...` alias with no counterpart under the project root), so each
/// alias needs its own document instead of the first one winning.
///
/// Documents with no mapping are dependency-generated: the indexer walked into
/// them on its own (a vendored gem, a type stub under `node_modules`). Those
/// are not ours to rename and pass through untouched.
///
/// Every appended document owns its arrays. The first alias reuses the arrays
/// the decoder produced and each additional alias receives a deep copy,
/// because `scip.freeDocument` releases those arrays per document.
fn remapExternalDocuments(
    allocator: std.mem.Allocator,
    mappings: []const ExternalReindexPath,
    documents: []scip.Document,
    out: *std.ArrayListUnmanaged(scip.Document),
) !void {
    // Each document either passes through once or fans out across the
    // mappings that name it, so this bound cannot be exceeded.
    try out.ensureUnusedCapacity(allocator, documents.len + mappings.len);

    for (documents) |doc| {
        var aliases: usize = 0;
        for (mappings) |mapping| {
            if (!std.mem.eql(u8, doc.relative_path, mapping.physical_path)) continue;
            aliases += 1;
            if (aliases == 1) {
                var first = doc;
                first.relative_path = mapping.logical_path;
                out.appendAssumeCapacity(first);
            } else {
                // A failed copy costs this one alias its document until the
                // next reindex; it must never cost two aliases one shared
                // array, which `scip.freeDocument` would release twice.
                var extra = dupeDocumentBody(allocator, doc) catch {
                    aliases -= 1;
                    debug_log.log("remapExternalDocuments: alias copy failed logical={s}", .{mapping.logical_path});
                    continue;
                };
                extra.relative_path = mapping.logical_path;
                out.appendAssumeCapacity(extra);
            }
            debug_log.log("remapExternalDocuments: alias logical={s} physical={s}", .{
                mapping.logical_path,
                mapping.physical_path,
            });
        }
        if (aliases == 0) {
            debug_log.log("remapExternalDocuments: unmapped document retained path={s}", .{doc.relative_path});
            out.appendAssumeCapacity(doc);
        }
    }
}

/// The logical namespace `PathMatcher` gives to approved external roots.
/// Nothing else produces it, which is what makes it a reliable ownership mark.
const external_alias_prefix = "@external/";

/// Decide whether a document in the master index belongs to the source set
/// this project manages.
///
/// A full resync converges the index onto the freshly matched set, so a
/// managed document that is no longer matched has to go — the file was
/// deleted, the configured patterns narrowed, or a negative pattern now
/// excludes it.
///
/// External indexers also emit documents nobody configured: a type stub under
/// `node_modules`, a vendored gem, an absolute path into a language runtime.
/// `PathMatcher` never traverses those locations, so cog's own collection can
/// never produce such a path — their absence from the matched set says nothing
/// about whether they are stale. Deleting them on every resync would throw
/// away the cross-repository symbols that make go-to-definition work into
/// dependencies, and no configured pattern could rebuild them.
///
/// So a path is managed exactly when the matcher could have produced it: an
/// `@external/...` alias, or a relative path the shared policy does not
/// exclude. Absolute paths and paths inside excluded directories are the
/// indexer's, not ours.
fn isManagedDocumentPath(logical_path: []const u8) bool {
    if (logical_path.len == 0) return false;
    if (std.mem.startsWith(u8, logical_path, external_alias_prefix)) return true;
    if (std.fs.path.isAbsolute(logical_path)) return false;
    return !path_matcher.isPolicyExcluded(logical_path);
}

fn appendConfiguredReindexPaths(
    allocator: std.mem.Allocator,
    matched_files: []const path_matcher.MatchedPath,
    indexed_documents: []const scip.Document,
    out: *std.ArrayListUnmanaged(ReindexPath),
) !void {
    try out.ensureTotalCapacity(allocator, matched_files.len + indexed_documents.len);
    for (matched_files) |file| {
        out.appendAssumeCapacity(.{
            .logical_path = file.logical_path,
            .physical_path = file.physical_path,
        });
    }
    for (indexed_documents) |doc| {
        if (findPhysicalPath(matched_files, doc.relative_path) != null) continue;
        if (!isManagedDocumentPath(doc.relative_path)) {
            debug_log.log("reindexConfiguredFiles: retaining unmanaged document path={s}", .{doc.relative_path});
            continue;
        }
        debug_log.log("reindexConfiguredFiles: removing stale managed document path={s}", .{doc.relative_path});
        out.appendAssumeCapacity(.{
            .logical_path = doc.relative_path,
            .physical_path = null,
        });
    }
}

pub const SYNC_WORKER_COMMAND = "__mcp-sync";

/// Percentage of the matched set above which a targeted batch loses to a
/// full resync: once most files must be re-parsed anyway, decoding and
/// merging the mostly-invalid old index is pure overhead.
const sync_full_resync_percent: usize = 40;

/// Manifest size at which reconciliation asks git for the changed-path set
/// instead of walking and statting the whole tree. A test seam, not a knob.
var git_fast_path_min_entries: usize = 10_000;

pub const SyncOutcome = enum { unchanged, changed, failed };

pub const SyncResult = struct {
    outcome: SyncOutcome,
    changed: usize = 0,
    removed: usize = 0,
    full_resync: bool = false,
};

/// Whether reconciliation should rebuild from the configured patterns rather
/// than patch the existing index.
fn shouldFullResync(manifest_missing: bool, changed: usize, removed: usize, matched: usize) bool {
    if (manifest_missing) return true;
    if (matched == 0) return changed + removed > 0;
    return (changed + removed) * 100 > matched * sync_full_resync_percent;
}

/// Reconcile the index with the working tree: stat every matched file
/// against the provenance manifest and repair only what drifted. The
/// in-sync case costs one directory walk plus one stat per file and never
/// opens the index.
pub fn syncConfiguredFiles(allocator: std.mem.Allocator) SyncResult {
    return syncConfiguredFilesInner(allocator, true);
}

/// Report drift without repairing it. Used by diagnostics.
pub fn scanConfiguredDrift(allocator: std.mem.Allocator) SyncResult {
    return syncConfiguredFilesInner(allocator, false);
}

fn syncConfiguredFilesInner(allocator: std.mem.Allocator, apply: bool) SyncResult {
    const failed: SyncResult = .{ .outcome = .failed };

    const cog_dir_path = paths.findCogDir(allocator) catch return failed;
    defer allocator.free(cog_dir_path);
    const project_root = std.fs.path.dirname(cog_dir_path) orelse return failed;

    var cog_dir = std.fs.openDirAbsolute(cog_dir_path, .{}) catch return failed;
    defer cog_dir.close();
    var sources = loadIndexSources(allocator, cog_dir) orelse return failed;
    defer sources.deinit(allocator);
    const manifest_missing = sources.manifest == null;

    // Git fast path: for large manifests in a git checkout, ask git for the
    // changed-path set instead of walking the whole tree. Git-ignored files
    // are invisible to it, and external roots live outside the repository,
    // so either condition keeps the full walk.
    var candidates: ?git_state.Candidates = null;
    defer if (candidates) |*c| c.deinit(allocator);
    var scan_all = true;
    if (sources.manifest) |m| {
        if (m.value.head_commit != null and
            sources.external_roots.len == 0 and
            m.value.entries.len >= git_fast_path_min_entries)
        {
            candidates = git_state.collectChangedSince(allocator, project_root, m.value.head_commit.?);
            if (candidates != null) {
                scan_all = false;
                debug_log.log("syncConfiguredFiles: git fast path candidates={d}", .{candidates.?.paths.items.len});
            } else {
                debug_log.log("syncConfiguredFiles: git fast path unavailable; walking the tree", .{});
            }
        }
    }

    var matched_files: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (matched_files.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        matched_files.deinit(allocator);
    }
    if (scan_all) {
        collectConfiguredFiles(
            allocator,
            project_root,
            sources.patterns,
            sources.external_roots,
            &matched_files,
        ) catch return failed;
    } else {
        // Only candidates the pattern set actually manages become work.
        var matcher = path_matcher.PathMatcher.init(allocator, .{
            .project_root = project_root,
            .patterns = sources.patterns,
            .external_roots = &.{},
        }) catch return failed;
        defer matcher.deinit();
        for (candidates.?.paths.items) |candidate| {
            if (!matcher.matches(candidate)) continue;
            const logical = allocator.dupe(u8, candidate) catch return failed;
            const physical = std.fs.path.join(allocator, &.{ project_root, candidate }) catch {
                allocator.free(logical);
                return failed;
            };
            matched_files.append(allocator, .{ .logical_path = logical, .physical_path = physical }) catch {
                allocator.free(logical);
                allocator.free(physical);
                return failed;
            };
        }
    }

    // `drifted` borrows strings from matched_files; `removed` and `refreshed`
    // borrow from the loaded manifest and matched set. All outlive their use.
    var drifted: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer drifted.deinit(allocator);
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer removed.deinit(allocator);
    var refreshed: std.ArrayListUnmanaged(index_manifest.Entry) = .empty;
    defer refreshed.deinit(allocator);

    if (sources.manifest) |loaded| {
        var by_path: std.StringHashMapUnmanaged(index_manifest.Entry) = .empty;
        defer by_path.deinit(allocator);
        for (loaded.value.entries) |entry| by_path.put(allocator, entry.path, entry) catch return failed;

        var matched_set: std.StringHashMapUnmanaged(void) = .empty;
        defer matched_set.deinit(allocator);

        for (matched_files.items) |file| {
            matched_set.put(allocator, file.logical_path, {}) catch return failed;
            const recorded = by_path.get(file.logical_path);
            // Stat the physical path — identical to the logical path through
            // the project root for ordinary files, and the only statable
            // location for external-root aliases.
            const current = index_manifest.statPhysicalFile(file.physical_path, file.logical_path) orelse {
                if (scan_all) {
                    // The walk saw the file an instant ago; treat the vanish
                    // as drift and let the batch settle it.
                    drifted.append(allocator, file) catch return failed;
                } else if (recorded != null) {
                    // A git candidate whose file is gone is a deletion.
                    removed.append(allocator, file.logical_path) catch return failed;
                }
                continue;
            };
            const known = recorded orelse {
                drifted.append(allocator, file) catch return failed;
                continue;
            };
            if (current.size == known.size and current.mtime_ns == known.mtime_ns) continue;

            // Content confirmation: checkout churn restores identical bytes
            // under fresh mtimes; those files need a manifest refresh, not a
            // reindex.
            if (known.hash) |expected| {
                if (index_manifest.hashPhysicalFile(allocator, file.physical_path)) |actual| {
                    if (actual == expected) {
                        var refreshed_entry = current;
                        refreshed_entry.hash = expected;
                        refreshed.append(allocator, refreshed_entry) catch return failed;
                        continue;
                    }
                }
            }
            drifted.append(allocator, file) catch return failed;
        }
        if (scan_all) {
            // Absence-based removal needs the complete matched set; the fast
            // path detects deletions through its candidates instead.
            for (loaded.value.entries) |entry| {
                if (!matched_set.contains(entry.path)) {
                    removed.append(allocator, entry.path) catch return failed;
                }
            }
        }
    }

    debug_log.log("syncConfiguredFiles: matched={d} drifted={d} removed={d} refreshed={d} manifest_missing={any} apply={any}", .{
        matched_files.items.len,
        drifted.items.len,
        removed.items.len,
        refreshed.items.len,
        manifest_missing,
        apply,
    });

    if (!manifest_missing and drifted.items.len == 0 and removed.items.len == 0) {
        if (apply and refreshed.items.len > 0) {
            refreshManifestEntries(allocator, cog_dir, sources.manifest.?.value, refreshed.items);
        }
        return .{ .outcome = .unchanged };
    }

    // The fast path's matched set is only the candidates, so drift ratios
    // are judged against the manifest's full document count.
    const drift_denominator = if (scan_all)
        matched_files.items.len
    else
        sources.manifest.?.value.entries.len;
    const full = shouldFullResync(manifest_missing, drifted.items.len, removed.items.len, drift_denominator);
    const report: SyncResult = .{
        .outcome = .changed,
        .changed = if (manifest_missing) matched_files.items.len else drifted.items.len,
        .removed = removed.items.len,
        .full_resync = full,
    };
    if (!apply) return report;

    if (full) {
        debug_log.log("syncConfiguredFiles: escalating to full resync", .{});
        if (!reindexConfiguredFiles(allocator)) return failed;
        return report;
    }

    const lock_fd = acquireIndexLock(allocator, cog_dir_path) orelse return failed;
    defer releaseIndexLock(lock_fd);
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir_path}) catch return failed;
    defer allocator.free(index_path);

    // Declared before the index so its deinit runs last: merged documents
    // borrow their strings from this store and must not outlive it.
    var backing_store: IndexBackingStore = .{};
    defer backing_store.deinit(allocator);

    const loaded_index = loadExistingIndex(allocator, index_path);
    var master_index = loaded_index.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded_index.backing_data) |data| allocator.free(data);

    var batch: std.ArrayListUnmanaged(ReindexPath) = .empty;
    defer batch.deinit(allocator);
    for (drifted.items) |file| {
        batch.append(allocator, .{
            .logical_path = file.logical_path,
            .physical_path = file.physical_path,
        }) catch return failed;
    }
    for (removed.items) |logical_path| {
        batch.append(allocator, .{ .logical_path = logical_path, .physical_path = null }) catch return failed;
    }

    if (!applyReindexBatch(allocator, &master_index, batch.items, &backing_store)) return failed;
    if (!saveIndex(allocator, master_index, index_path, .{
        .aliases = matched_files.items,
        .patterns = sources.patterns,
        .external_roots = sources.external_roots,
    })) return failed;
    return report;
}

/// Resolved pattern configuration for index maintenance: settings when
/// present, otherwise the pattern set recorded in the manifest, so projects
/// indexed with explicit CLI patterns reconcile without a settings entry.
const IndexSources = struct {
    settings: ?settings_mod.Settings,
    manifest: ?index_manifest.Loaded,
    patterns: []const []const u8,
    external_roots: []const []const u8,

    fn deinit(self: *IndexSources, allocator: std.mem.Allocator) void {
        if (self.settings) |s| s.deinit(allocator);
        if (self.manifest) |*m| m.deinit();
    }
};

fn loadIndexSources(allocator: std.mem.Allocator, cog_dir: std.fs.Dir) ?IndexSources {
    var sources: IndexSources = .{
        .settings = settings_mod.Settings.load(allocator),
        .manifest = index_manifest.load(allocator, cog_dir),
        .patterns = &.{},
        .external_roots = &.{},
    };
    if (sources.settings) |s| {
        if (s.code) |c| {
            sources.patterns = c.index orelse &.{};
            sources.external_roots = c.external_roots orelse &.{};
        }
    }
    if (sources.patterns.len == 0) {
        if (sources.manifest) |m| {
            debug_log.log("loadIndexSources: using {d} manifest-recorded patterns", .{m.value.patterns.len});
            sources.patterns = m.value.patterns;
            if (sources.external_roots.len == 0) sources.external_roots = m.value.external_roots;
        }
    }
    if (sources.patterns.len == 0) {
        sources.deinit(allocator);
        return null;
    }
    return sources;
}

/// Rewrite manifest entries whose content proved identical under fresh
/// stats, so the hash confirmation is not repeated on every future scan.
fn refreshManifestEntries(
    allocator: std.mem.Allocator,
    cog_dir: std.fs.Dir,
    old: index_manifest.ManifestFile,
    refreshed: []const index_manifest.Entry,
) void {
    var by_path: std.StringHashMapUnmanaged(index_manifest.Entry) = .empty;
    defer by_path.deinit(allocator);
    for (refreshed) |entry| by_path.put(allocator, entry.path, entry) catch return;

    var updated: std.ArrayListUnmanaged(index_manifest.Entry) = .empty;
    defer updated.deinit(allocator);
    for (old.entries) |entry| {
        updated.append(allocator, by_path.get(entry.path) orelse entry) catch return;
    }

    debug_log.log("refreshManifestEntries: refreshing {d} of {d} entries", .{ refreshed.len, old.entries.len });
    _ = index_manifest.write(allocator, cog_dir, .{
        .version = index_manifest.manifest_version,
        .patterns = old.patterns,
        .external_roots = old.external_roots,
        .head_commit = old.head_commit,
        .entries = updated.items,
    });
}

/// Hidden worker entry: reconcile in a dedicated process so the MCP server
/// never runs allocator-heavy indexing on its own threads.
pub fn runSyncWorker(allocator: std.mem.Allocator) u8 {
    debug_log.log("sync worker: starting reconcile", .{});
    const result = syncConfiguredFiles(allocator);
    const exit_code: u8 = switch (result.outcome) {
        .changed => 0,
        .unchanged => 1,
        .failed => 2,
    };
    debug_log.log("sync worker: completed outcome={s} changed={d} removed={d} full={any}", .{
        @tagName(result.outcome),
        result.changed,
        result.removed,
        result.full_resync,
    });
    return exit_code;
}

fn codeSync(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        printCommandHelp(help.code_sync);
        return;
    }

    const started_ms = std.time.milliTimestamp();
    const result = syncConfiguredFiles(allocator);
    const elapsed_ms = std.time.milliTimestamp() - started_ms;
    switch (result.outcome) {
        .unchanged => printErr("  Index is in sync with the working tree.\n"),
        .changed => {
            var buffer: [160]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buffer,
                "  Index updated: {d} file(s) reindexed, {d} removed{s} ({d} ms).\n",
                .{ result.changed, result.removed, if (result.full_resync) " via full resync" else "", elapsed_ms },
            ) catch "  Index updated.\n";
            printErr(line);
        },
        .failed => {
            printErr("error: index sync failed; run with --debug for details or rebuild with cog code:index\n");
            return error.Explained;
        },
    }
}

/// Owns the string storage that indexed documents borrow from.
///
/// A `scip.Document` owns its `occurrences` and `symbols` arrays but only
/// *borrows* every string inside them — symbol ids, display names and, for
/// external indexers, the relative path — from a backing buffer produced by
/// the indexer: tree-sitter's `result.string_data`, or an external indexer's
/// decoded `result.backing_data`. Documents merged into the master index
/// therefore outlive the batch that produced them, so these buffers must stay
/// alive until the index has been *encoded*, not merely until the batch ends.
///
/// Ownership lives with the caller of `applyReindexBatch` for exactly that
/// reason: the caller encodes via `saveIndex` and only then releases the
/// store. Freeing the buffers inside the batch is a use-after-free in
/// `scip_encode`.
const IndexBackingStore = struct {
    buffers: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Take ownership of `buffer`. Returns false when the buffer could not be
    /// retained, in which case it has already been freed and the caller must
    /// drop any document borrowing from it.
    fn take(self: *IndexBackingStore, allocator: std.mem.Allocator, buffer: []const u8) bool {
        self.buffers.append(allocator, buffer) catch {
            debug_log.log("IndexBackingStore: retain failed bytes={d}", .{buffer.len});
            allocator.free(buffer);
            return false;
        };
        return true;
    }

    fn deinit(self: *IndexBackingStore, allocator: std.mem.Allocator) void {
        debug_log.log("IndexBackingStore: releasing buffers={d}", .{self.buffers.items.len});
        for (self.buffers.items) |buffer| allocator.free(buffer);
        self.buffers.deinit(allocator);
    }
};

/// Merge a batch of re-indexed files into `master_index`.
///
/// String storage for every merged document is handed to `store`, which the
/// caller must keep alive until after the index is encoded.
/// Pair watcher-supplied logical paths with the physical source each one
/// aliases.
///
/// The watcher emits logical paths, so a single physical file can arrive
/// under several names — `src/main.zig`, a symlink alias `src-link/main.zig`,
/// or an `@external/...` alias that has no counterpart under the project
/// root. Each logical name must keep its own document while reading the one
/// physical source behind it.
///
/// Paths with no match fall back to themselves so ordinary relative paths and
/// genuine deletions still resolve through the existence check.
fn appendAliasedReindexPaths(
    allocator: std.mem.Allocator,
    logical_paths: []const []const u8,
    matched_files: []const path_matcher.MatchedPath,
    out: *std.ArrayListUnmanaged(ReindexPath),
) !void {
    try out.ensureTotalCapacity(allocator, logical_paths.len);
    for (logical_paths) |logical_path| {
        const physical_path = findPhysicalPath(matched_files, logical_path) orelse logical_path;
        if (physical_path.ptr != logical_path.ptr) {
            debug_log.log("reindexFiles: alias logical={s} physical={s}", .{ logical_path, physical_path });
        }
        out.appendAssumeCapacity(.{
            .logical_path = logical_path,
            .physical_path = physical_path,
        });
    }
}

/// Collect the configured logical/physical pairs used to resolve aliases.
///
/// Best effort: a project without configured index patterns leaves `out`
/// empty, and callers then treat logical paths as physical.
fn collectAliasSources(
    allocator: std.mem.Allocator,
    cog_dir: []const u8,
    out: *std.ArrayListUnmanaged(path_matcher.MatchedPath),
) void {
    const settings = settings_mod.Settings.load(allocator) orelse return;
    defer settings.deinit(allocator);
    const code = settings.code orelse return;
    const patterns = code.index orelse return;
    const project_root = std.fs.path.dirname(cog_dir) orelse return;
    debug_log.log("reindexFiles: resolving aliases project_root={s}", .{project_root});
    collectConfiguredFiles(
        allocator,
        project_root,
        patterns,
        code.external_roots orelse &.{},
        out,
    ) catch |err| {
        debug_log.log("reindexFiles: alias resolution failed error={s}; using logical paths", .{@errorName(err)});
    };
}

fn applyReindexBatch(
    allocator: std.mem.Allocator,
    master_index: *scip.Index,
    file_paths: []const ReindexPath,
    store: *IndexBackingStore,
) bool {
    var changed = false;

    var external_symbol_list: std.ArrayListUnmanaged(scip.SymbolInformation) = .empty;
    defer {
        for (external_symbol_list.items) |*sym| freeSymbolInformation(allocator, sym);
        external_symbol_list.deinit(allocator);
    }
    external_symbol_list.ensureTotalCapacity(allocator, master_index.external_symbols.len) catch return false;
    external_symbol_list.appendSliceAssumeCapacity(master_index.external_symbols);
    if (master_index.external_symbols.len > 0) allocator.free(master_index.external_symbols);
    master_index.external_symbols = &.{};

    var indexer = tree_sitter_indexer.Indexer.init();
    defer indexer.deinit();

    var seen_names: [16][]const u8 = undefined;
    var unique_exts: [16]extensions.Extension = undefined;
    var ext_files: [16]std.ArrayListUnmanaged([]const u8) = [_]std.ArrayListUnmanaged([]const u8){.empty} ** 16;
    var ext_mappings: [16]std.ArrayListUnmanaged(ExternalReindexPath) = [_]std.ArrayListUnmanaged(ExternalReindexPath){.empty} ** 16;
    var num_unique: usize = 0;
    defer for (0..num_unique) |ext_idx| {
        ext_files[ext_idx].deinit(allocator);
        ext_mappings[ext_idx].deinit(allocator);
    };

    var ext_cache_keys: [32][]const u8 = undefined;
    var ext_cache_vals: [32]?extensions.Extension = undefined;
    var ext_cache_installed: [32]bool = [_]bool{false} ** 32;
    var ext_cache_len: usize = 0;
    defer for (0..ext_cache_len) |ci| {
        if (ext_cache_installed[ci]) {
            if (ext_cache_vals[ci]) |*value| extensions.freeExtension(allocator, value);
        }
    };

    for (file_paths) |file| {
        const logical_path = file.logical_path;
        const physical_path = file.physical_path orelse {
            const before = master_index.documents.len;
            removeDocument(allocator, master_index, logical_path);
            if (master_index.documents.len != before) {
                changed = true;
                debug_log.log("reindexFiles: queued removal path={s}", .{logical_path});
            }
            continue;
        };
        const exists = blk: {
            std.fs.cwd().access(physical_path, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) {
            const before = master_index.documents.len;
            removeDocument(allocator, master_index, logical_path);
            if (master_index.documents.len != before) {
                changed = true;
                debug_log.log("reindexFiles: queued removal path={s}", .{logical_path});
            }
            continue;
        }

        const ext = std.fs.path.extension(logical_path);
        if (ext.len == 0) continue;
        const resolved = blk: {
            for (ext_cache_keys[0..ext_cache_len], ext_cache_vals[0..ext_cache_len]) |key, value| {
                if (std.mem.eql(u8, key, ext)) break :blk value;
            }
            const value = extensions.resolveByExtension(allocator, ext);
            if (ext_cache_len < ext_cache_keys.len) {
                ext_cache_keys[ext_cache_len] = ext;
                ext_cache_vals[ext_cache_len] = value;
                ext_cache_installed[ext_cache_len] = if (value) |resolved_ext| resolved_ext.installed else false;
                ext_cache_len += 1;
            }
            break :blk value;
        } orelse continue;
        const idx = resolved.indexer orelse continue;

        switch (idx) {
            .tree_sitter => |ts_config| {
                debug_log.log("reindexFiles: reading logical={s} physical={s}", .{ logical_path, physical_path });
                const source = readFileContents(allocator, physical_path) orelse continue;
                defer allocator.free(source);
                const result = indexer.indexFile(allocator, source, logical_path, ts_config) catch {
                    mergeDocument(allocator, master_index, .{
                        .language = ts_config.scip_name,
                        .relative_path = logical_path,
                        .occurrences = &.{},
                        .symbols = &.{},
                    });
                    changed = true;
                    continue;
                };
                if (!store.take(allocator, result.string_data)) continue;
                mergeDocument(allocator, master_index, result.doc);
                changed = true;
            },
            .scip_binary => {
                var found_idx: ?usize = null;
                for (seen_names[0..num_unique], 0..) |name, i| {
                    if (std.mem.eql(u8, name, resolved.name)) {
                        found_idx = i;
                        break;
                    }
                }
                const mapping: ExternalReindexPath = .{
                    .logical_path = logical_path,
                    .physical_path = physical_path,
                };
                if (found_idx) |i| {
                    ext_files[i].append(allocator, physical_path) catch {};
                    ext_mappings[i].append(allocator, mapping) catch {};
                } else if (num_unique < unique_exts.len) {
                    seen_names[num_unique] = resolved.name;
                    unique_exts[num_unique] = resolved;
                    ext_files[num_unique].append(allocator, physical_path) catch {};
                    ext_mappings[num_unique].append(allocator, mapping) catch {};
                    num_unique += 1;
                }
            },
        }
    }

    for (0..num_unique) |ext_idx| {
        const scip_config = switch (unique_exts[ext_idx].indexer orelse continue) {
            .scip_binary => |config| config,
            .tree_sitter => continue,
        };
        const batch_files = ext_files[ext_idx].items;
        if (batch_files.len == 0) continue;
        debug_log.log("reindexFiles: spawning external batch command={s} files={d}", .{ scip_config.command, batch_files.len });
        const result = invokeIndexerForFileList(allocator, batch_files, scip_config, null) catch |err| {
            debug_log.log("reindexFiles: external batch failed command={s} error={s}", .{ scip_config.command, @errorName(err) });
            continue;
        };
        if (!store.take(allocator, result.backing_data.?)) {
            var failed_index = result.index;
            scip.freeIndex(allocator, &failed_index);
            continue;
        }
        var remapped: std.ArrayListUnmanaged(scip.Document) = .empty;
        defer remapped.deinit(allocator);
        // Only the capacity reservation can fail here; a failed alias copy is
        // absorbed inside the remap, so no document is left half-owned.
        remapExternalDocuments(allocator, ext_mappings[ext_idx].items, result.index.documents, &remapped) catch {
            debug_log.log("reindexFiles: alias remap failed command={s} docs={d}", .{
                scip_config.command,
                result.index.documents.len,
            });
            for (result.index.documents) |*doc| scip.freeDocument(allocator, doc);
            allocator.free(result.index.documents);
            for (result.index.external_symbols) |*sym| freeSymbolInformation(allocator, sym);
            allocator.free(result.index.external_symbols);
            continue;
        };
        for (remapped.items) |doc| mergeDocument(allocator, master_index, doc);
        allocator.free(result.index.documents);
        for (result.index.external_symbols) |sym| mergeExternalSymbolList(allocator, &external_symbol_list, sym);
        allocator.free(result.index.external_symbols);
        changed = true;
    }

    master_index.external_symbols = external_symbol_list.toOwnedSlice(allocator) catch return false;
    return changed;
}

/// Re-index or remove multiple files in a single locked index transaction.
/// Input paths are deduplicated, the existing index is loaded once, external
/// indexers receive one batch per extension, and one atomic replacement is made.
pub fn reindexFiles(allocator: std.mem.Allocator, file_paths: []const []const u8) bool {
    const unique = deduplicateFilePaths(allocator, file_paths) catch return false;
    defer allocator.free(unique);
    if (unique.len == 0) return false;
    debug_log.log("reindexFiles: batching input={d} unique={d}", .{ file_paths.len, unique.len });

    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);
    const lock_fd = acquireIndexLock(allocator, cog_dir) orelse return false;
    defer releaseIndexLock(lock_fd);

    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    // Declared before the index so its deinit runs last: merged documents
    // borrow their strings from this store and must not outlive it.
    var backing_store: IndexBackingStore = .{};
    defer backing_store.deinit(allocator);

    debug_log.log("reindexFiles: loading index path={s}", .{index_path});
    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    // Only pay for alias resolution when a path is not directly readable from
    // the project root. Ordinary edits and symlink aliases resolve as-is; an
    // unreadable path is either an @external alias or a real deletion, and
    // only the matcher can tell those apart.
    const needs_alias_resolution = blk: {
        for (unique) |file_path| {
            std.fs.cwd().access(file_path, .{}) catch break :blk true;
        }
        break :blk false;
    };

    var alias_sources: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (alias_sources.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        alias_sources.deinit(allocator);
    }
    if (needs_alias_resolution) collectAliasSources(allocator, cog_dir, &alias_sources);

    var batch: std.ArrayListUnmanaged(ReindexPath) = .empty;
    defer batch.deinit(allocator);
    appendAliasedReindexPaths(allocator, unique, alias_sources.items, &batch) catch return false;
    if (!applyReindexBatch(allocator, &master_index, batch.items, &backing_store)) return false;
    debug_log.log("reindexFiles: encoding documents={d}", .{master_index.documents.len});
    return saveIndex(allocator, master_index, index_path, .{ .aliases = if (alias_sources.items.len > 0) alias_sources.items else null });
}

/// Reconcile all configured index patterns after watcher event loss.
pub fn reindexConfiguredFiles(allocator: std.mem.Allocator) bool {
    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);
    const project_root = std.fs.path.dirname(cog_dir) orelse return false;

    var cog_dir_handle = std.fs.openDirAbsolute(cog_dir, .{}) catch return false;
    defer cog_dir_handle.close();
    var sources = loadIndexSources(allocator, cog_dir_handle) orelse return false;
    defer sources.deinit(allocator);

    var matched_files: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (matched_files.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        matched_files.deinit(allocator);
    }
    collectConfiguredFiles(
        allocator,
        project_root,
        sources.patterns,
        sources.external_roots,
        &matched_files,
    ) catch return false;

    const lock_fd = acquireIndexLock(allocator, cog_dir) orelse return false;
    defer releaseIndexLock(lock_fd);
    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    // Declared before the index so its deinit runs last: merged documents
    // borrow their strings from this store and must not outlive it.
    var backing_store: IndexBackingStore = .{};
    defer backing_store.deinit(allocator);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    var batch: std.ArrayListUnmanaged(ReindexPath) = .empty;
    defer batch.deinit(allocator);
    appendConfiguredReindexPaths(allocator, matched_files.items, master_index.documents, &batch) catch return false;
    debug_log.log("reindexConfiguredFiles: reconciliation current={d} batch={d}", .{ matched_files.items.len, batch.items.len });
    if (!applyReindexBatch(allocator, &master_index, batch.items, &backing_store)) return false;
    return saveIndex(allocator, master_index, index_path, .{
        .aliases = matched_files.items,
        .patterns = sources.patterns,
        .external_roots = sources.external_roots,
    });
}

/// Remove a file from the SCIP index on disk.
pub fn removeFileFromIndex(allocator: std.mem.Allocator, file_path: []const u8) bool {
    return reindexFiles(allocator, &.{file_path});
}

/// Re-index a single file and update the master index.
pub fn reindexFile(allocator: std.mem.Allocator, file_path: []const u8) bool {
    return reindexFiles(allocator, &.{file_path});
}

/// Write and save an index to disk.
fn saveIndex(
    allocator: std.mem.Allocator,
    index: scip.Index,
    index_path: []const u8,
    sources: ManifestSources,
) bool {
    const encoded = scip_encode.encodeIndex(allocator, index) catch return false;
    defer allocator.free(encoded);

    if (!writeEncodedIndexAtomically(allocator, index_path, encoded)) return false;
    writeManifestForIndex(allocator, index_path, index.documents, sources);
    return true;
}

/// Provenance inputs a caller can hand the manifest writer; anything omitted
/// is resolved from settings or carried forward from the previous manifest.
const ManifestSources = struct {
    aliases: ?[]const path_matcher.MatchedPath = null,
    patterns: ?[]const []const u8 = null,
    external_roots: ?[]const []const u8 = null,
};

/// Refresh the provenance manifest after a successful index write. Manifest
/// problems are logged, never propagated: a missing manifest only means the
/// next reconcile falls back to a full resync.
fn writeManifestForIndex(
    allocator: std.mem.Allocator,
    index_path: []const u8,
    documents: []const scip.Document,
    sources: ManifestSources,
) void {
    const cog_dir_path = std.fs.path.dirname(index_path) orelse return;
    const project_root = std.fs.path.dirname(cog_dir_path) orelse return;

    var root_dir = std.fs.openDirAbsolute(project_root, .{}) catch |err| {
        debug_log.log("writeManifestForIndex: cannot open project root {s}: {s}", .{ project_root, @errorName(err) });
        return;
    };
    defer root_dir.close();
    var cog_dir = std.fs.openDirAbsolute(cog_dir_path, .{}) catch |err| {
        debug_log.log("writeManifestForIndex: cannot open {s}: {s}", .{ cog_dir_path, @errorName(err) });
        return;
    };
    defer cog_dir.close();

    // The previous manifest carries hashes forward for unchanged files and
    // is the last-resort pattern source.
    var previous = index_manifest.load(allocator, cog_dir);
    defer if (previous) |*p| p.deinit();
    var previous_by_path: std.StringHashMapUnmanaged(index_manifest.Entry) = .empty;
    defer previous_by_path.deinit(allocator);
    if (previous) |p| {
        for (p.value.entries) |entry| previous_by_path.put(allocator, entry.path, entry) catch return;
    }

    var resolved_aliases: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (resolved_aliases.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        resolved_aliases.deinit(allocator);
    }
    var alias_slice: []const path_matcher.MatchedPath = sources.aliases orelse &.{};
    if (sources.aliases == null) {
        for (documents) |doc| {
            if (!std.mem.startsWith(u8, doc.relative_path, external_alias_prefix)) continue;
            collectAliasSources(allocator, cog_dir_path, &resolved_aliases);
            alias_slice = resolved_aliases.items;
            break;
        }
    }

    var physical_by_logical: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer physical_by_logical.deinit(allocator);
    for (alias_slice) |file| {
        physical_by_logical.put(allocator, file.logical_path, file.physical_path) catch return;
    }

    // Recorded pattern set: caller, then settings, then previous manifest.
    var settings_owner: ?settings_mod.Settings = null;
    defer if (settings_owner) |s| s.deinit(allocator);
    var patterns: []const []const u8 = sources.patterns orelse &.{};
    var external_roots: []const []const u8 = sources.external_roots orelse &.{};
    if (patterns.len == 0) {
        settings_owner = settings_mod.Settings.load(allocator);
        if (settings_owner) |s| {
            if (s.code) |c| {
                patterns = c.index orelse &.{};
                if (external_roots.len == 0) external_roots = c.external_roots orelse &.{};
            }
        }
    }
    if (patterns.len == 0) {
        if (previous) |p| {
            patterns = p.value.patterns;
            if (external_roots.len == 0) external_roots = p.value.external_roots;
        }
    }

    var entries: std.ArrayListUnmanaged(index_manifest.Entry) = .empty;
    defer entries.deinit(allocator);
    for (documents) |doc| {
        if (!isManagedDocumentPath(doc.relative_path)) continue;
        const physical = physical_by_logical.get(doc.relative_path);
        const stat_entry = if (physical) |physical_path|
            index_manifest.statPhysicalFile(physical_path, doc.relative_path)
        else
            index_manifest.statFile(root_dir, doc.relative_path);
        var entry = stat_entry orelse continue;

        // Hash carry-forward: only files whose stats moved are re-read.
        if (previous_by_path.get(entry.path)) |old| {
            if (old.size == entry.size and old.mtime_ns == entry.mtime_ns and old.hash != null) {
                entry.hash = old.hash;
            }
        }
        if (entry.hash == null) {
            entry.hash = hashManifestTarget(allocator, project_root, physical, doc.relative_path);
        }

        entries.append(allocator, entry) catch |err| {
            debug_log.log("writeManifestForIndex: entry collection failed: {s}", .{@errorName(err)});
            return;
        };
    }

    const head_commit = git_state.resolveHeadCommit(allocator, project_root);
    defer if (head_commit) |commit| allocator.free(commit);

    _ = index_manifest.write(allocator, cog_dir, .{
        .version = index_manifest.manifest_version,
        .patterns = patterns,
        .external_roots = external_roots,
        .head_commit = head_commit,
        .entries = entries.items,
    });
}

fn hashManifestTarget(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    physical: ?[]const u8,
    logical_path: []const u8,
) ?u64 {
    if (physical) |physical_path| {
        return index_manifest.hashPhysicalFile(allocator, physical_path);
    }
    const absolute = std.fs.path.join(allocator, &.{ project_root, logical_path }) catch return null;
    defer allocator.free(absolute);
    return index_manifest.hashPhysicalFile(allocator, absolute);
}

fn writeEncodedIndexAtomically(allocator: std.mem.Allocator, index_path: []const u8, encoded: []const u8) bool {
    debug_log.log("writeEncodedIndexAtomically: starting path={s} bytes={d}", .{ index_path, encoded.len });
    const parent = std.fs.path.dirname(index_path) orelse return false;
    const basename = std.fs.path.basename(index_path);
    const tmp_name = std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ basename, std.time.nanoTimestamp() }) catch return false;
    defer allocator.free(tmp_name);

    var dir = std.fs.openDirAbsolute(parent, .{}) catch return false;
    defer dir.close();

    var tmp_file = dir.createFile(tmp_name, .{}) catch return false;
    var renamed = false;
    defer {
        tmp_file.close();
        if (!renamed) dir.deleteFile(tmp_name) catch {};
    }

    tmp_file.writeAll(encoded) catch return false;
    tmp_file.sync() catch return false;
    dir.rename(tmp_name, basename) catch |err| {
        debug_log.log("writeEncodedIndexAtomically: rename failed error={s}", .{@errorName(err)});
        return false;
    };
    renamed = true;
    debug_log.log("writeEncodedIndexAtomically: replaced path={s}", .{index_path});
    return true;
}

fn runExternalTool(allocator: std.mem.Allocator, cfg: settings_mod.ToolConfig, subs: []const settings_mod.Substitution) !void {
    const sub_args = settings_mod.substituteArgs(allocator, cfg.args, subs) catch {
        printErr("error: failed to substitute tool args\n");
        return error.Explained;
    };
    defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

    const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
    defer allocator.free(full_args);
    full_args[0] = cfg.command;
    @memcpy(full_args[1..], sub_args);

    var child = std.process.Child.init(full_args, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    if (term.Exited != 0) {
        printErr("error: external tool exited with non-zero status\n");
        return error.Explained;
    }
}

fn builtinEdit(allocator: std.mem.Allocator, file_path: []const u8, old_text: []const u8, new_text: []const u8) !void {
    // Read file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        printErr("error: file not found: ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch {
        printErr("error: failed to read file\n");
        return error.Explained;
    };
    defer allocator.free(content);

    // Find old_text — check for ambiguity
    const first_pos = std.mem.indexOf(u8, content, old_text) orelse {
        printErr("error: old text not found in ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };

    // Check for second occurrence
    if (first_pos + old_text.len < content.len) {
        if (std.mem.indexOf(u8, content[first_pos + old_text.len ..], old_text)) |_| {
            // Count total occurrences
            var count: usize = 0;
            var pos: usize = 0;
            while (pos < content.len) {
                if (std.mem.indexOf(u8, content[pos..], old_text)) |idx| {
                    count += 1;
                    pos = pos + idx + old_text.len;
                } else break;
            }
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "error: old text is ambiguous (found {d} occurrences) — provide more context\n", .{count}) catch "error: old text is ambiguous\n";
            printErr(count_str);
            return error.Explained;
        }
    }

    // Build new content
    const new_len = content.len - old_text.len + new_text.len;
    const new_content = allocator.alloc(u8, new_len) catch {
        printErr("error: out of memory\n");
        return error.Explained;
    };
    defer allocator.free(new_content);

    @memcpy(new_content[0..first_pos], content[0..first_pos]);
    @memcpy(new_content[first_pos..][0..new_text.len], new_text);
    const after_old = first_pos + old_text.len;
    @memcpy(new_content[first_pos + new_text.len ..], content[after_old..]);

    // Write back
    const out_file = std.fs.cwd().createFile(file_path, .{}) catch {
        printErr("error: failed to write file\n");
        return error.Explained;
    };
    defer out_file.close();
    out_file.writeAll(new_content) catch {
        printErr("error: failed to write file\n");
        return error.Explained;
    };
}

fn builtinCreate(file_path: []const u8, content: []const u8) !void {
    // Create parent directories if needed
    if (std.fs.path.dirname(file_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {
            printErr("error: failed to create parent directories\n");
            return error.Explained;
        };
    }

    const file = std.fs.cwd().createFile(file_path, .{ .exclusive = true }) catch {
        printErr("error: file already exists: ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();

    if (content.len > 0) {
        file.writeAll(content) catch {
            printErr("error: failed to write file content\n");
            return error.Explained;
        };
    }
}

fn builtinDelete(file_path: []const u8) !void {
    std.fs.cwd().deleteFile(file_path) catch {
        printErr("error: failed to delete file: ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };
}

/// Remove a file's document from the index and save.
fn removeFromIndex(allocator: std.mem.Allocator, file_path: []const u8) bool {
    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);

    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    removeDocument(allocator, &master_index, file_path);
    return saveIndex(allocator, master_index, index_path, .{});
}

fn builtinRename(old_path: []const u8, new_path: []const u8) !void {
    // Create parent directories for new path if needed
    if (std.fs.path.dirname(new_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    std.fs.cwd().rename(old_path, new_path) catch {
        printErr("error: failed to rename ");
        printErr(old_path);
        printErr(" to ");
        printErr(new_path);
        printErr("\n");
        return error.Explained;
    };
}

// ── Public Inner API (for MCP server) ───────────────────────────────────

pub const QueryMode = enum { find, refs, symbols, imports, contains, calls, callers, overview };

pub const QueryDirection = enum { incoming, outgoing, both };

pub const OverviewScope = enum { symbol, file, repo };

pub const QueryParams = struct {
    mode: QueryMode,
    name: ?[]const u8 = null,
    file: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    direction: QueryDirection = .outgoing,
    scope: OverviewScope = .symbol,
};

pub fn codeQueryInner(allocator: std.mem.Allocator, params: QueryParams) ![]const u8 {
    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    return codeQueryWithLoadedIndex(allocator, &ci, params);
}

pub fn codeQueryWithLoadedIndex(allocator: std.mem.Allocator, ci: *CodeIndex, params: QueryParams) ![]const u8 {
    debug_log.log("codeQueryWithLoadedIndex: mode={s} name={?s} file={?s} direction={s} scope={s}", .{ @tagName(params.mode), params.name, params.file, @tagName(params.direction), @tagName(params.scope) });
    return switch (params.mode) {
        .find => try queryFindInner(allocator, ci, params.name orelse return error.MissingName, params.kind, params.file),
        .refs => try queryRefsInner(allocator, ci, params.name orelse return error.MissingName, params.kind, params.file),
        .symbols => try querySymbolsInner(allocator, ci, params.file orelse return error.MissingFile, params.kind),
        .imports => try queryImportsInner(allocator, ci, params.name, params.file, params.direction),
        .contains => try queryContainsInner(allocator, ci, params.name, params.file, params.direction),
        .calls => try queryCallsInner(allocator, ci, params.name orelse return error.MissingName),
        .callers => try queryCallersInner(allocator, ci, params.name orelse return error.MissingName),
        .overview => try queryOverviewInner(allocator, ci, params.name, params.file, params.scope),
    };
}

const MAX_BATCH_QUERIES = 32;

pub fn codeQueryBatchWithLoadedIndex(allocator: std.mem.Allocator, ci: *CodeIndex, queries: []const QueryParams) ![]const u8 {
    debug_log.log("codeQueryBatchWithLoadedIndex: queries={d}", .{queries.len});
    if (queries.len == 0) return error.Explained;
    if (queries.len == 1) return codeQueryWithLoadedIndex(allocator, ci, queries[0]);

    const n = @min(queries.len, MAX_BATCH_QUERIES);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    for (0..n) |i| {
        const params = queries[i];
        if (i > 0) try writer.writeAll("\n\n");

        // Write a header for each query in the batch
        try writer.writeAll("── ");
        try writer.writeAll(@tagName(params.mode));
        if (params.name) |name| {
            try writer.writeAll(" name=");
            try writer.writeAll(name);
        }
        if (params.file) |file| {
            try writer.writeAll(" file=");
            try writer.writeAll(file);
        }
        try writer.writeAll(" ──\n");

        const result = codeQueryWithLoadedIndex(allocator, ci, params) catch |err| {
            try writer.writeAll("(error: ");
            try writer.writeAll(@errorName(err));
            try writer.writeAll(")\n");
            continue;
        };
        defer allocator.free(result);
        try writer.writeAll(result);

        if (buf.items.len >= MAX_TOTAL_BYTES) {
            try writer.writeAll("\n\n(output truncated — batch budget exceeded)");
            break;
        }
    }

    if (queries.len > MAX_BATCH_QUERIES) {
        try writer.writeAll("\n\n(batch truncated — max 32 queries per call)");
    }

    return buf.toOwnedSlice(allocator);
}

// ── Explore API (composite find + read) ─────────────────────────────────

pub const ExploreQuery = struct {
    name: []const u8,
    kind: ?[]const u8 = null,
};

pub const ExploreOptions = struct {
    context_lines: usize = 15,
    include_relationships: bool = false,
    include_architecture: bool = false,
    overview_scope: OverviewScope = .symbol,
};

pub fn codeExploreWithLoadedIndex(allocator: std.mem.Allocator, ci: *CodeIndex, queries: []const ExploreQuery, options: ExploreOptions) ![]const u8 {
    debug_log.log("codeExploreWithLoadedIndex: queries={d} context_lines={d} include_relationships={} include_architecture={} overview_scope={s}", .{ queries.len, options.context_lines, options.include_relationships, options.include_architecture, @tagName(options.overview_scope) });
    // Resolve the project root from .cog dir (strip trailing /.cog)
    const cog_dir = paths.findCogDir(allocator) catch return try allocator.dupe(u8, "[]");
    defer allocator.free(cog_dir);
    const project_root = std.fs.path.dirname(cog_dir) orelse return try allocator.dupe(u8, "[]");

    // Phase 1: Gather all candidates
    const n = @min(queries.len, MAX_EXPLORE_QUERIES);
    var all_matches: [MAX_EXPLORE_QUERIES]CodeIndex.MatchList = undefined;
    for (0..n) |i| {
        all_matches[i] = ci.findSymbol(allocator, queries[i].name, queries[i].kind, null) catch .empty;
    }
    defer for (0..n) |i| all_matches[i].deinit(allocator);

    // Phase 2: Auto-retry not-found queries with *name* glob
    var retry_used: [MAX_EXPLORE_QUERIES]bool = .{false} ** MAX_EXPLORE_QUERIES;
    var retry_globs: [MAX_EXPLORE_QUERIES]?[]const u8 = .{null} ** MAX_EXPLORE_QUERIES;
    defer for (&retry_globs) |*rg| {
        if (rg.*) |g| allocator.free(g);
    };

    for (0..n) |i| {
        if (all_matches[i].items.len > 0) continue;
        // Skip if already a glob pattern
        if (hasGlobChars(queries[i].name)) continue;
        const glob_name = try std.fmt.allocPrint(allocator, "*{s}*", .{queries[i].name});
        retry_globs[i] = glob_name;
        all_matches[i] = ci.findSymbol(allocator, glob_name, queries[i].kind, null) catch .empty;
        if (all_matches[i].items.len > 0) retry_used[i] = true;
    }

    // Phase 3: Disambiguate using batch coherence
    const selected = try disambiguateBatch(allocator, ci, all_matches[0..n]);
    defer allocator.free(selected);

    // Phase 4: Read definition bodies and collect queried file/symbol info
    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);

    // Store body results for primary queries
    var body_results: [MAX_EXPLORE_QUERIES]?ReadBodyResult = .{null} ** MAX_EXPLORE_QUERIES;
    defer for (&body_results) |*br| {
        if (br.*) |r| allocator.free(r.snippet);
    };

    for (0..n) |i| {
        const matches = &all_matches[i];
        if (matches.items.len == 0) continue;
        const sel_idx = selected[i] orelse 0;
        const match = matches.items[sel_idx];
        if (match.def.path.len == 0) continue;

        // Track queried symbols so file_symbols TOC excludes them
        queried_symbols.put(allocator, match.symbol, {}) catch {};

        // Read full definition body
        const body = readDefinitionBody(allocator, project_root, match.def.path, match.def.line, match.def.end_line, options.context_lines) catch null;
        if (body) |b| {
            body_results[i] = b;
        }
    }

    // Phase 5: Output readable text
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var w = &aw.writer;

    // Track files we've already emitted TOCs for (avoid duplicates across queries)
    var emitted_file_tocs: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted_file_tocs.deinit(allocator);

    // Primary results
    for (0..n) |i| {
        if (i > 0) try w.writeAll("\n---\n\n");

        const matches = &all_matches[i];
        if (matches.items.len == 0) {
            try w.print("`{s}`\nNot found.\n", .{queries[i].name});
            continue;
        }

        const sel_idx = selected[i] orelse 0;
        const match = matches.items[sel_idx];

        if (match.def.path.len == 0) {
            try w.print("`{s}`\nExternal symbol (no source file).\n", .{queries[i].name});
            continue;
        }

        const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);
        try w.print("`{s}` ({s})\n`", .{ display_name, scip.kindName(match.def.kind) });
        try writePathSpan(w, match.def.path, match.def.line, match.def.end_line);
        try w.writeAll("`\n");
        if (retry_used[i]) {
            try w.print("Matched with retry pattern `{s}`\n", .{retry_globs[i].?});
        }

        if (body_results[i]) |body| {
            try w.writeAll("\nSnippet:\n");
            try writeSnippetBlock(w, body.snippet, match.def.path, body.truncated);
        }

        if (options.include_relationships or options.include_architecture) {
            const overview_text = try queryOverviewInner(allocator, ci, display_name, null, .symbol);
            defer allocator.free(overview_text);
            try w.writeAll("\nArchitecture:\n");
            try w.writeAll(overview_text);
            try w.writeByte('\n');
        }

        // Emit references from SCIP cross-reference data
        if (match.def.end_line > match.def.line) {
            var refs = ci.findReferencesInRange(allocator, match.def.path, match.symbol, match.def.line, match.def.end_line);
            defer refs.deinit(allocator);
            if (refs.items.len > 0) {
                try w.writeAll("\nReferences:\n");
                const shown = @min(refs.items.len, MAX_TEXT_REFS);
                for (refs.items[0..shown]) |ref_name| {
                    try w.print("- `{s}`\n", .{ref_name});
                }
                if (refs.items.len > shown) {
                    try w.writeAll("\nMore results exist; narrow the query for more detail.\n");
                }
            }
        }

        // Emit file_symbols TOC (once per unique file)
        if (!emitted_file_tocs.contains(match.def.path)) {
            emitted_file_tocs.put(allocator, match.def.path, {}) catch {};
            var toc = ci.getFileSymbolsTOC(allocator, match.def.path, &queried_symbols);
            defer toc.deinit(allocator);
            if (toc.items.len > 0) {
                try w.writeAll("\nNearby:\n");
                const shown = @min(toc.items.len, MAX_TEXT_NEARBY_SYMBOLS);
                for (toc.items[0..shown]) |entry| {
                    try w.print("- `{s}` ({s}) `", .{ entry.name, scip.kindName(entry.kind) });
                    try writeLineRange(w, entry.line, entry.end_line);
                    try w.writeAll("`\n");
                }
                if (toc.items.len > shown) {
                    try w.writeAll("\nMore results exist; narrow the query for more detail.\n");
                }
            }
        }

        if (aw.writer.buffered().len >= MAX_TOTAL_BYTES) {
            try w.writeAll("\nOutput truncated to stay within the explore tool budget. Narrow the query or ask follow-up questions for more detail.\n");
            break;
        }
    }

    debug_log.log("codeExploreWithLoadedIndex: emitted {d} bytes", .{aw.writer.buffered().len});

    if (options.include_architecture and options.overview_scope == .repo) {
        const repo_overview = try queryOverviewInner(allocator, ci, null, null, .repo);
        defer allocator.free(repo_overview);
        try aw.writer.writeAll("\n---\n\n");
        try aw.writer.writeAll(repo_overview);
    }

    return aw.toOwnedSlice();
}

fn writeExploreError(s: *Stringify, name: []const u8, err_msg: []const u8) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("error");
    try s.write(err_msg);
    try s.endObject();
}

fn readSnippet(allocator: std.mem.Allocator, project_root: []const u8, rel_path: []const u8, def_line: i32, context_lines: usize) ![]const u8 {
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Find line boundaries
    const target: usize = if (def_line > 0) @intCast(def_line) else 0;
    const start_line = if (target >= context_lines) target - context_lines else 0;
    const end_line = target + context_lines;

    var line_num: usize = 0;
    var start_offset: usize = 0;
    var end_offset: usize = content.len;
    var i: usize = 0;

    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line_num += 1;
            if (line_num == start_line) {
                start_offset = i + 1;
            }
            if (line_num == end_line) {
                end_offset = i;
                break;
            }
        }
    }

    if (start_offset >= content.len) start_offset = content.len;
    if (end_offset > content.len) end_offset = content.len;
    if (start_offset > end_offset) start_offset = end_offset;

    return try allocator.dupe(u8, content[start_offset..end_offset]);
}

const ReadBodyResult = struct {
    snippet: []const u8,
    truncated: bool,
};

fn readDefinitionBody(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    rel_path: []const u8,
    def_line: i32,
    def_end_line: i32,
    fallback_context: usize,
) !ReadBodyResult {
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Split into lines
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);
    var line_start: usize = 0;
    for (content, 0..) |ch, idx| {
        if (ch == '\n') {
            try lines.append(allocator, content[line_start..idx]);
            line_start = idx + 1;
        }
    }
    if (line_start < content.len) {
        try lines.append(allocator, content[line_start..]);
    }

    if (lines.items.len == 0) return .{ .snippet = try allocator.dupe(u8, ""), .truncated = false };

    const raw_target: usize = if (def_line > 0) @intCast(def_line) else 0;
    const target: usize = @min(raw_target, lines.items.len - 1);

    // Walk backward from def_line for doc comments (up to CONTEXT_BEFORE lines)
    var doc_start = target;
    {
        var look: usize = 0;
        while (look < CONTEXT_BEFORE and doc_start > 0) : (look += 1) {
            const prev = lines.items[doc_start - 1];
            const trimmed = std.mem.trimLeft(u8, prev, " \t");
            if (trimmed.len == 0) break;
            if (std.mem.startsWith(u8, trimmed, "///") or
                std.mem.startsWith(u8, trimmed, "//!") or
                std.mem.startsWith(u8, trimmed, "//") or
                std.mem.startsWith(u8, trimmed, "/*") or
                std.mem.startsWith(u8, trimmed, "* ") or
                std.mem.startsWith(u8, trimmed, "*/") or
                std.mem.startsWith(u8, trimmed, "#") or
                std.mem.startsWith(u8, trimmed, "@"))
            {
                doc_start -= 1;
            } else {
                break;
            }
        }
    }

    // Determine end line
    const has_enclosing_range = def_end_line > def_line;
    const end_line: usize = if (has_enclosing_range)
        @min(@as(usize, @intCast(def_end_line)), lines.items.len - 1)
    else blk: {
        // No enclosing_range — fallback to ±fallback_context window
        break :blk @min(target + fallback_context, lines.items.len - 1);
    };

    // When no enclosing_range, extend doc_start to include fallback window before target
    const actual_start = if (has_enclosing_range)
        doc_start
    else
        @min(doc_start, if (target >= fallback_context) target - fallback_context else 0);

    // Cap at MAX_BODY_LINES
    const capped_end = @min(end_line, actual_start + MAX_BODY_LINES - 1);
    const truncated = capped_end < end_line;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (actual_start..capped_end + 1) |li| {
        try buf.appendSlice(allocator, lines.items[li]);
        try buf.append(allocator, '\n');
    }
    return .{
        .snippet = try buf.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

const RelatedSymbol = struct {
    symbol: []const u8,
    def: DefInfo,
    relevance: usize,
};

fn discoverRelatedSymbols(
    allocator: std.mem.Allocator,
    ci: *const CodeIndex,
    queried_files: []const []const u8,
    queried_symbols: *const std.StringHashMapUnmanaged(void),
    max_related: usize,
) !std.ArrayListUnmanaged(RelatedSymbol) {
    // Build occurrence sets for each unique queried file
    var file_occ_sets: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer {
        for (file_occ_sets.items) |*s| s.deinit(allocator);
        file_occ_sets.deinit(allocator);
    }

    // Track unique files to avoid building duplicate sets
    var seen_files: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_files.deinit(allocator);

    for (queried_files) |file_path| {
        if (seen_files.contains(file_path)) continue;
        seen_files.put(allocator, file_path, {}) catch continue;
        const occ_set = ci.buildFileOccurrenceSet(allocator, file_path);
        try file_occ_sets.append(allocator, occ_set);
    }

    // Collect candidate symbols and score by how many queried files reference them
    var candidates: std.StringHashMapUnmanaged(RelatedSymbol) = .empty;
    defer candidates.deinit(allocator);

    for (file_occ_sets.items) |occ_set| {
        var occ_iter = occ_set.iterator();
        while (occ_iter.next()) |entry| {
            const sym = entry.key_ptr.*;
            // Skip already-queried symbols
            if (queried_symbols.contains(sym)) continue;

            // Look up def info — skip external symbols
            const def = ci.symbol_to_defs.get(sym) orelse continue;
            if (def.path.len == 0) continue;

            const existing = candidates.getOrPut(allocator, sym) catch continue;
            if (!existing.found_existing) {
                existing.value_ptr.* = .{
                    .symbol = sym,
                    .def = def,
                    .relevance = 1,
                };
            } else {
                existing.value_ptr.relevance += 1;
            }
        }
    }

    // Collect into sortable list
    var result: std.ArrayListUnmanaged(RelatedSymbol) = .empty;
    errdefer result.deinit(allocator);
    var cand_iter = candidates.iterator();
    while (cand_iter.next()) |entry| {
        try result.append(allocator, entry.value_ptr.*);
    }

    // Sort by relevance descending, then kind priority (struct=49 > function=12 > others)
    const SortCtx = struct {
        fn lessThan(_: void, a: RelatedSymbol, b: RelatedSymbol) bool {
            if (a.relevance != b.relevance) return a.relevance > b.relevance;
            return kindPriority(a.def.kind) > kindPriority(b.def.kind);
        }

        fn kindPriority(kind: i32) u8 {
            return switch (kind) {
                49 => 3, // struct
                7 => 3, // class
                12 => 2, // function
                24 => 2, // method
                else => 1,
            };
        }
    };
    std.mem.sortUnstable(RelatedSymbol, result.items, {}, SortCtx.lessThan);

    // Truncate to max_related
    if (result.items.len > max_related) {
        result.items.len = max_related;
    }

    return result;
}

fn resolveIndexedPath(ci: *CodeIndex, requested_path: []const u8) ?[]const u8 {
    if (ci.path_to_doc_idx.contains(requested_path)) return requested_path;
    var iter = ci.path_to_doc_idx.iterator();
    while (iter.next()) |entry| {
        const indexed_path = entry.key_ptr.*;
        if (fileMatchesSuffix(indexed_path, requested_path)) return indexed_path;
    }
    return null;
}

fn resolveSymbolMatch(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8) !?CodeIndex.MatchEntry {
    var matches = try ci.findSymbol(allocator, name, null, null);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return null;
    return matches.items[0];
}

fn resolveSymbolMatchForCallGraph(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8, callers: bool) !?CodeIndex.MatchEntry {
    var matches = try ci.findSymbol(allocator, name, null, null);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return null;

    for (matches.items) |match| {
        if (callers) {
            if (ci.getCallers(match.symbol)) |rels| {
                if (rels.items.len > 0) return match;
            }
        } else {
            if (ci.getCalls(match.symbol)) |rels| {
                if (rels.items.len > 0) return match;
            }
        }
    }

    return matches.items[0];
}

fn writeRelationshipList(writer: anytype, ci: *CodeIndex, relationships: []const RelationshipInfo, filter_kind: ?[]const u8) !usize {
    var emitted: usize = 0;
    for (relationships) |rel| {
        if (filter_kind) |kind| {
            if (!std.mem.eql(u8, rel.kind, kind)) continue;
        }
        const def = ci.symbol_to_defs.get(rel.symbol);
        const display_name = if (def) |d|
            if (d.display_name.len > 0) d.display_name else scip.extractSymbolName(rel.symbol)
        else if (std.mem.startsWith(u8, rel.symbol, "cog/import/"))
            rel.symbol["cog/import/".len..]
        else
            scip.extractSymbolName(rel.symbol);
        try writer.print("- `{s}` [{s}]", .{ display_name, rel.kind });
        if (def) |d| {
            if (d.path.len > 0) {
                try writer.writeAll(" `");
                try writePathSpan(writer, d.path, d.line, d.end_line);
                try writer.writeAll("`");
            }
        }
        try writer.writeByte('\n');
        emitted += 1;
    }
    return emitted;
}

fn queryFindInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8, kind_filter: ?[]const u8, file_filter: ?[]const u8) ![]const u8 {
    var matches = try ci.findSymbol(allocator, name, kind_filter, file_filter);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return try allocator.dupe(u8, "Symbol not found");

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const shown = @min(matches.items.len, MAX_TEXT_FIND_MATCHES);
    try aw.writer.print("Matches for `{s}`:\n", .{name});
    for (matches.items[0..shown]) |match| {
        const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);
        try aw.writer.print("- `{s}` ({s}) `", .{ display_name, scip.kindName(match.def.kind) });
        try writePathSpan(&aw.writer, match.def.path, match.def.line, match.def.end_line);
        try aw.writer.writeAll("`\n");
    }
    if (matches.items.len > shown) {
        try aw.writer.writeAll("\nMore results exist; narrow the query for more detail.\n");
    }

    debug_log.log("queryFindInner: emitted {d} matches for {s}", .{ shown, name });
    return aw.toOwnedSlice();
}

fn queryRefsInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8, kind_filter: ?[]const u8, file_filter: ?[]const u8) ![]const u8 {
    var matches = try ci.findSymbol(allocator, name, kind_filter, null);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return try allocator.dupe(u8, "Symbol not found");

    const match = matches.items[0];
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);
    try aw.writer.print("References for `{s}` ({s})\n", .{ display_name, scip.kindName(match.def.kind) });
    try aw.writer.print("Definition: `{s}:{d}`\n", .{ match.def.path, match.def.line });
    try aw.writer.writeByte('\n');

    var total_refs: usize = 0;
    var shown_refs: usize = 0;
    if (ci.symbol_to_refs.get(match.symbol)) |refs| {
        total_refs = refs.items.len;
        for (refs.items) |ref| {
            if (file_filter) |ff| {
                if (!fileMatchesSuffix(ref.path, ff)) continue;
            }
            if (shown_refs < MAX_TEXT_REFS) {
                try aw.writer.print("- `{s}:{d}`\n", .{ ref.path, ref.line });
            }
            shown_refs += 1;
        }
    }

    if (shown_refs == 0) {
        try aw.writer.writeAll("- No references found\n");
    } else if (shown_refs > MAX_TEXT_REFS) {
        try aw.writer.writeAll("\nMore results exist; narrow the query for more detail.\n");
    }
    if (file_filter) |ff| {
        try aw.writer.print("Filter: `{s}`\n", .{ff});
    }
    try aw.writer.print("Total: {d}\n", .{total_refs});

    debug_log.log("queryRefsInner: emitted {d} refs for {s}", .{ shown_refs, name });
    return aw.toOwnedSlice();
}

fn querySymbolsInner(allocator: std.mem.Allocator, ci: *CodeIndex, file_path: []const u8, kind_filter: ?[]const u8) ![]const u8 {
    // Try exact match first
    const resolved_path = resolveIndexedPath(ci, file_path) orelse return try allocator.dupe(u8, "File not found in index");
    const doc_idx = ci.path_to_doc_idx.get(resolved_path).?;
    const doc = ci.index.documents[doc_idx];

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("Symbols in `{s}`:\n", .{doc.relative_path});

    var emitted: usize = 0;
    for (doc.symbols) |sym| {
        const k = scip.kindName(sym.kind);
        if (kind_filter) |kf| {
            if (!std.ascii.eqlIgnoreCase(k, kf)) continue;
        }
        var def_line: i32 = 0;
        for (doc.occurrences) |occ| {
            if (std.mem.eql(u8, occ.symbol, sym.symbol) and scip.SymbolRole.isDefinition(occ.symbol_roles)) {
                def_line = occ.range.start_line;
                break;
            }
        }
        const display = if (sym.display_name.len > 0) sym.display_name else scip.extractSymbolName(sym.symbol);
        if (emitted < MAX_TEXT_FILE_SYMBOLS) {
            try aw.writer.print("- `{s}` ({s}) `", .{ display, k });
            try writeLineRange(&aw.writer, def_line, def_line);
            try aw.writer.writeAll("`\n");
        }
        emitted += 1;
    }

    if (emitted == 0) {
        try aw.writer.writeAll("- No matching symbols found\n");
    } else if (emitted > MAX_TEXT_FILE_SYMBOLS) {
        try aw.writer.writeAll("\nMore results exist; narrow the query for more detail.\n");
    }

    debug_log.log("querySymbolsInner: emitted {d} symbols for {s}", .{ emitted, doc.relative_path });
    return aw.toOwnedSlice();
}

fn queryImportsInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: ?[]const u8, file_path: ?[]const u8, direction: QueryDirection) ![]const u8 {
    const target_file = if (file_path) |fp|
        resolveIndexedPath(ci, fp) orelse return try allocator.dupe(u8, "File not found in index")
    else if (name) |n| blk: {
        const match = (try resolveSymbolMatch(allocator, ci, n)) orelse return try allocator.dupe(u8, "Symbol not found");
        break :blk match.def.path;
    } else return error.MissingFile;

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("Imports for `{s}`\n", .{target_file});

    var emitted: usize = 0;
    if (direction == .outgoing or direction == .both) {
        try aw.writer.writeAll("Outgoing:\n");
        if (ci.getFileImports(target_file)) |imports| {
            for (imports.items) |item| {
                try aw.writer.print("- `{s}`\n", .{item.label});
                emitted += 1;
            }
        }
        if (emitted == 0) try aw.writer.writeAll("- No imports found\n");
    }

    if (direction == .incoming or direction == .both) {
        if (direction == .both) try aw.writer.writeByte('\n');
        try aw.writer.writeAll("Incoming:\n");
        var incoming: usize = 0;
        var iter = ci.file_to_imports.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |item| {
                if (std.mem.eql(u8, item.label, target_file) or std.mem.eql(u8, item.symbol, target_file)) {
                    try aw.writer.print("- `{s}`\n", .{entry.key_ptr.*});
                    incoming += 1;
                    break;
                }
                if (std.mem.startsWith(u8, item.symbol, "cog/import/") and std.mem.eql(u8, item.symbol["cog/import/".len..], target_file)) {
                    try aw.writer.print("- `{s}`\n", .{entry.key_ptr.*});
                    incoming += 1;
                    break;
                }
            }
        }
        if (incoming == 0) try aw.writer.writeAll("- No importers found\n");
    }

    return aw.toOwnedSlice();
}

fn queryContainsInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: ?[]const u8, file_path: ?[]const u8, direction: QueryDirection) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    if (file_path) |fp| {
        const resolved_path = resolveIndexedPath(ci, fp) orelse return try allocator.dupe(u8, "File not found in index");
        try aw.writer.print("Contains for `{s}`\n", .{resolved_path});
        var excluded: std.StringHashMapUnmanaged(void) = .empty;
        defer excluded.deinit(allocator);
        var toc = ci.getFileSymbolsTOC(allocator, resolved_path, &excluded);
        defer toc.deinit(allocator);
        if (toc.items.len == 0) {
            try aw.writer.writeAll("- No contained symbols found\n");
        } else {
            for (toc.items) |entry| {
                try aw.writer.print("- `{s}` ({s}) `", .{ entry.name, scip.kindName(entry.kind) });
                try writeLineRange(&aw.writer, entry.line, entry.end_line);
                try aw.writer.writeAll("`\n");
            }
        }
        return aw.toOwnedSlice();
    }

    const target_name = name orelse return error.MissingName;
    const match = (try resolveSymbolMatch(allocator, ci, target_name)) orelse return try allocator.dupe(u8, "Symbol not found");
    const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);
    try aw.writer.print("Contains for `{s}` ({s})\n", .{ display_name, scip.kindName(match.def.kind) });

    var emitted: usize = 0;
    if (direction == .incoming or direction == .both) {
        try aw.writer.writeAll("Parent:\n");
        if (ci.getParent(match.symbol)) |parent_symbol| {
            if (ci.symbol_to_defs.get(parent_symbol)) |parent_def| {
                const parent_name = if (parent_def.display_name.len > 0) parent_def.display_name else scip.extractSymbolName(parent_symbol);
                try aw.writer.print("- `{s}` ({s}) `", .{ parent_name, scip.kindName(parent_def.kind) });
                try writePathSpan(&aw.writer, parent_def.path, parent_def.line, parent_def.end_line);
                try aw.writer.writeAll("`\n");
                emitted += 1;
            }
        }
        if (emitted == 0) try aw.writer.writeAll("- No parent container found\n");
    }

    if (direction == .outgoing or direction == .both) {
        if (direction == .both) try aw.writer.writeByte('\n');
        try aw.writer.writeAll("Children:\n");
        const before_children = emitted;
        if (ci.getChildren(match.symbol)) |children| {
            emitted += try writeRelationshipList(&aw.writer, ci, children.items, "contains");
        }
        if (emitted == before_children) try aw.writer.writeAll("- No contained symbols found\n");
    }

    return aw.toOwnedSlice();
}

fn queryCallsInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8) ![]const u8 {
    const match = (try resolveSymbolMatchForCallGraph(allocator, ci, name, false)) orelse return try allocator.dupe(u8, "Symbol not found");
    const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("Calls from `{s}` ({s})\n", .{ display_name, scip.kindName(match.def.kind) });
    try aw.writer.print("Definition: `{s}:", .{match.def.path});
    try writeLineRange(&aw.writer, match.def.line, match.def.end_line);
    try aw.writer.writeAll("`\n\n");

    if (ci.getCalls(match.symbol)) |rels| {
        const emitted = try writeRelationshipList(&aw.writer, ci, rels.items, "calls");
        if (emitted == 0) try aw.writer.writeAll("- No calls found\n");
    } else {
        try aw.writer.writeAll("- No calls found\n");
    }
    return aw.toOwnedSlice();
}

fn queryCallersInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8) ![]const u8 {
    const match = (try resolveSymbolMatchForCallGraph(allocator, ci, name, true)) orelse return try allocator.dupe(u8, "Symbol not found");
    const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("Callers of `{s}` ({s})\n", .{ display_name, scip.kindName(match.def.kind) });
    try aw.writer.print("Definition: `{s}:", .{match.def.path});
    try writeLineRange(&aw.writer, match.def.line, match.def.end_line);
    try aw.writer.writeAll("`\n\n");

    if (ci.getCallers(match.symbol)) |rels| {
        const emitted = try writeRelationshipList(&aw.writer, ci, rels.items, "callers");
        if (emitted == 0) try aw.writer.writeAll("- No callers found\n");
    } else {
        try aw.writer.writeAll("- No callers found\n");
    }
    return aw.toOwnedSlice();
}

fn collectTopFilesByFanout(allocator: std.mem.Allocator, ci: *CodeIndex) !std.ArrayListUnmanaged(FileStat) {
    var stats: std.ArrayListUnmanaged(FileStat) = .empty;
    errdefer stats.deinit(allocator);

    var iter = ci.path_to_doc_idx.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const doc = ci.index.documents[entry.value_ptr.*];
        try stats.append(allocator, .{
            .path = path,
            .symbol_count = doc.symbols.len,
            .import_count = if (ci.getFileImports(path)) |imports| imports.items.len else 0,
        });
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: FileStat, b: FileStat) bool {
            if (a.import_count == b.import_count) return a.symbol_count > b.symbol_count;
            return a.import_count > b.import_count;
        }
    };
    std.mem.sortUnstable(FileStat, stats.items, {}, SortCtx.lessThan);
    return stats;
}

fn countIncomingImports(ci: *CodeIndex, target_file: []const u8) usize {
    var total: usize = 0;
    var iter = ci.file_to_imports.iterator();
    while (iter.next()) |entry| {
        if (ci.getFileImports(entry.key_ptr.*)) |imports| {
            for (imports.items) |item| {
                if (std.mem.eql(u8, item.label, target_file)) {
                    total += 1;
                    break;
                }
                if (std.mem.startsWith(u8, item.symbol, "cog/import/") and std.mem.eql(u8, item.symbol["cog/import/".len..], target_file)) {
                    total += 1;
                    break;
                }
            }
        }
    }
    return total;
}

fn collectEntrypoints(allocator: std.mem.Allocator, ci: *CodeIndex) !std.ArrayListUnmanaged(EntrypointStat) {
    var stats: std.ArrayListUnmanaged(EntrypointStat) = .empty;
    errdefer stats.deinit(allocator);

    var iter = ci.symbol_to_defs.iterator();
    while (iter.next()) |entry| {
        const symbol = entry.key_ptr.*;
        const def = entry.value_ptr.*;
        if (def.path.len == 0) continue;
        const name_text = if (def.display_name.len > 0) def.display_name else scip.extractSymbolName(symbol);

        var score: i32 = 0;
        if (std.mem.eql(u8, name_text, "main")) score += 100;
        if (std.mem.eql(u8, name_text, "bootstrap") or std.mem.eql(u8, name_text, "run")) score += 35;
        if (std.mem.endsWith(u8, def.path, "main.zig") or std.mem.endsWith(u8, def.path, "main.ts") or std.mem.endsWith(u8, def.path, "main.js")) score += 40;
        if (!CodeIndex.pathIsTest(def.path)) score += 10;
        if (ci.getCalls(symbol)) |calls| score += @as(i32, @intCast(@min(calls.items.len * 10, 40)));
        score += @as(i32, @intCast(@min(countIncomingImports(ci, def.path) * 5, 25)));
        if (score <= 0) continue;

        try stats.append(allocator, .{
            .symbol = symbol,
            .path = def.path,
            .line = def.line,
            .end_line = def.end_line,
            .score = score,
        });
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: EntrypointStat, b: EntrypointStat) bool {
            if (a.score == b.score) return std.mem.lessThan(u8, a.path, b.path);
            return a.score > b.score;
        }
    };
    std.mem.sortUnstable(EntrypointStat, stats.items, {}, SortCtx.lessThan);
    return stats;
}

fn collectSubsystemStats(allocator: std.mem.Allocator, ci: *CodeIndex) !std.ArrayListUnmanaged(SubsystemStat) {
    var subsystem_files: std.StringHashMapUnmanaged(usize) = .empty;
    defer subsystem_files.deinit(allocator);
    var subsystem_imports: std.StringHashMapUnmanaged(usize) = .empty;
    defer subsystem_imports.deinit(allocator);

    var iter = ci.path_to_doc_idx.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse continue;
        const rest = path[slash + 1 ..];
        const next = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const prefix = rest[0..next];

        const files_gop = try subsystem_files.getOrPut(allocator, prefix);
        if (!files_gop.found_existing) files_gop.value_ptr.* = 0;
        files_gop.value_ptr.* += 1;

        const imports_gop = try subsystem_imports.getOrPut(allocator, prefix);
        if (!imports_gop.found_existing) imports_gop.value_ptr.* = 0;
        imports_gop.value_ptr.* += if (ci.getFileImports(path)) |imports| imports.items.len else 0;
    }

    var result: std.ArrayListUnmanaged(SubsystemStat) = .empty;
    errdefer result.deinit(allocator);
    var files_iter = subsystem_files.iterator();
    while (files_iter.next()) |entry| {
        try result.append(allocator, .{
            .name = entry.key_ptr.*,
            .file_count = entry.value_ptr.*,
            .import_count = subsystem_imports.get(entry.key_ptr.*) orelse 0,
        });
    }

    const SortCtx = struct {
        fn lessThan(_: void, a: SubsystemStat, b: SubsystemStat) bool {
            if (a.file_count == b.file_count) {
                if (a.import_count == b.import_count) return std.mem.lessThan(u8, a.name, b.name);
                return a.import_count > b.import_count;
            }
            return a.file_count > b.file_count;
        }
    };
    std.mem.sortUnstable(SubsystemStat, result.items, {}, SortCtx.lessThan);
    return result;
}

fn writeSubsystemSummary(allocator: std.mem.Allocator, writer: anytype, ci: *CodeIndex) !void {
    var stats = try collectSubsystemStats(allocator, ci);
    defer stats.deinit(allocator);

    try writer.writeAll("Subsystems:\n");
    var emitted: usize = 0;
    for (stats.items) |entry| {
        try writer.print("- `{s}` ({d} files, {d} imports)\n", .{ entry.name, entry.file_count, entry.import_count });
        emitted += 1;
        if (emitted >= 8) break;
    }
    if (emitted == 0) try writer.writeAll("- No subsystem groupings inferred\n");
}

fn queryOverviewInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: ?[]const u8, file_path: ?[]const u8, scope: OverviewScope) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    switch (scope) {
        .repo => {
            try aw.writer.writeAll("Repository overview\n");
            try aw.writer.print("Files indexed: {d}\n", .{ci.index.documents.len});
            try aw.writer.print("Symbols indexed: {d}\n", .{ci.symbol_to_defs.count()});

            try aw.writer.writeByte('\n');
            try aw.writer.writeAll("Probable entrypoints:\n");
            var entrypoints = try collectEntrypoints(allocator, ci);
            defer entrypoints.deinit(allocator);
            var emitted_entrypoints: usize = 0;
            for (entrypoints.items) |entry| {
                try aw.writer.print("- `{s}` `", .{entry.path});
                try writeLineRange(&aw.writer, entry.line, entry.end_line);
                try aw.writer.print("` (score {d})\n", .{entry.score});
                emitted_entrypoints += 1;
                if (emitted_entrypoints >= 5) break;
            }
            if (emitted_entrypoints == 0) try aw.writer.writeAll("- No obvious entrypoints found\n");

            try aw.writer.writeByte('\n');
            try aw.writer.writeAll("Top files by import fan-out:\n");
            var stats = try collectTopFilesByFanout(allocator, ci);
            defer stats.deinit(allocator);
            var top_count: usize = 0;
            for (stats.items) |entry| {
                try aw.writer.print("- `{s}` ({d} imports, {d} symbols)\n", .{ entry.path, entry.import_count, entry.symbol_count });
                top_count += 1;
                if (top_count >= 8) break;
            }
            if (top_count == 0) try aw.writer.writeAll("- No import relationships found\n");

            try aw.writer.writeByte('\n');
            try writeSubsystemSummary(allocator, &aw.writer, ci);
        },
        .file => {
            const target_file = file_path orelse return error.MissingFile;
            const resolved_path = resolveIndexedPath(ci, target_file) orelse return try allocator.dupe(u8, "File not found in index");
            try aw.writer.print("File overview for `{s}`\n", .{resolved_path});
            try aw.writer.writeByte('\n');
            const imports_text = try queryImportsInner(allocator, ci, null, resolved_path, .outgoing);
            defer allocator.free(imports_text);
            try aw.writer.writeAll(imports_text);
            try aw.writer.writeByte('\n');
            const contains_text = try queryContainsInner(allocator, ci, null, resolved_path, .outgoing);
            defer allocator.free(contains_text);
            try aw.writer.writeAll(contains_text);
        },
        .symbol => {
            const target_name = name orelse return error.MissingName;
            const match = (try resolveSymbolMatch(allocator, ci, target_name)) orelse return try allocator.dupe(u8, "Symbol not found");
            const display_name = if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol);
            try aw.writer.print("Overview for `{s}` ({s})\n", .{ display_name, scip.kindName(match.def.kind) });
            try aw.writer.print("Definition: `{s}:", .{match.def.path});
            try writeLineRange(&aw.writer, match.def.line, match.def.end_line);
            try aw.writer.writeAll("`\n");

            try aw.writer.writeByte('\n');
            const contains_text = try queryContainsInner(allocator, ci, target_name, null, .both);
            defer allocator.free(contains_text);
            try aw.writer.writeAll(contains_text);

            if (ci.getRelationships(match.symbol)) |rels| {
                try aw.writer.writeByte('\n');
                try aw.writer.writeAll("Relationships:\n");
                const emitted = try writeRelationshipList(&aw.writer, ci, rels.items, null);
                if (emitted == 0) try aw.writer.writeAll("- No relationships found\n");
            }

            if (ci.getCalls(match.symbol)) |calls| {
                try aw.writer.writeByte('\n');
                try aw.writer.writeAll("Calls:\n");
                const emitted = try writeRelationshipList(&aw.writer, ci, calls.items, "calls");
                if (emitted == 0) try aw.writer.writeAll("- No calls found\n");
            }

            if (ci.getCallers(match.symbol)) |callers| {
                try aw.writer.writeByte('\n');
                try aw.writer.writeAll("Callers:\n");
                const emitted = try writeRelationshipList(&aw.writer, ci, callers.items, "callers");
                if (emitted == 0) try aw.writer.writeAll("- No callers found\n");
            }
        },
    }

    return aw.toOwnedSlice();
}

fn writeLineRange(writer: anytype, line: i32, end_line: i32) !void {
    if (end_line > line) {
        try writer.print("{d}-{d}", .{ line, end_line });
    } else {
        try writer.print("{d}", .{line});
    }
}

fn writePathSpan(writer: anytype, path: []const u8, line: i32, end_line: i32) !void {
    try writer.print("{s}:", .{path});
    try writeLineRange(writer, line, end_line);
}

fn truncateInline(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn writeSnippetBlock(writer: anytype, snippet: []const u8, path: []const u8, already_truncated: bool) !void {
    const clipped_result = clipSnippet(snippet);
    const snippet_text = clipped_result.text;
    const clipped = clipped_result.clipped;
    try writer.print("```{s}\n{s}```\n", .{ languageForPath(path), snippet_text });
    if (already_truncated or clipped) {
        try writer.writeAll("Snippet truncated. Narrow the query or read the file directly for the full body.\n");
    }
}

fn clipSnippet(snippet: []const u8) struct { text: []const u8, clipped: bool } {
    if (snippet.len <= MAX_TEXT_SNIPPET_BYTES) return .{ .text = snippet, .clipped = false };
    return .{ .text = snippet[0..MAX_TEXT_SNIPPET_BYTES], .clipped = true };
}

fn languageForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".zig")) return "zig";
    if (std.mem.endsWith(u8, path, ".py")) return "python";
    if (std.mem.endsWith(u8, path, ".rs")) return "rust";
    if (std.mem.endsWith(u8, path, ".js")) return "javascript";
    if (std.mem.endsWith(u8, path, ".ts")) return "ts";
    if (std.mem.endsWith(u8, path, ".tsx")) return "tsx";
    if (std.mem.endsWith(u8, path, ".jsx")) return "jsx";
    if (std.mem.endsWith(u8, path, ".c")) return "c";
    if (std.mem.endsWith(u8, path, ".cc") or std.mem.endsWith(u8, path, ".cpp")) return "cpp";
    if (std.mem.endsWith(u8, path, ".h") or std.mem.endsWith(u8, path, ".hpp")) return "cpp";
    return "text";
}

pub fn codeEditInner(allocator: std.mem.Allocator, file_path: []const u8, old_text: []const u8, new_text: []const u8) ![]const u8 {
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    const use_external = if (s) |ss| if (ss.code) |c| c.editor != null else false else false;
    if (use_external) {
        const editor_cfg = s.?.code.?.editor.?;
        const subs: []const settings_mod.Substitution = &.{
            .{ .key = "{file}", .value = file_path },
            .{ .key = "{old}", .value = old_text },
            .{ .key = "{new}", .value = new_text },
        };
        try runExternalTool(allocator, editor_cfg, subs);
    } else {
        try builtinEdit(allocator, file_path, old_text, new_text);
    }

    const reindexed = reindexFile(allocator, file_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("edited");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeCreateInner(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    const creator_cfg = if (s) |ss| if (ss.code) |c| c.creator else null else null;
    if (creator_cfg) |cfg| {
        const subs: []const settings_mod.Substitution = &.{
            .{ .key = "{file}", .value = file_path },
            .{ .key = "{content}", .value = content },
        };
        try runExternalTool(allocator, cfg, subs);
    } else {
        try builtinCreate(file_path, content);
    }

    const reindexed = reindexFile(allocator, file_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("created");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeDeleteInner(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    const deleter_cfg = if (s) |ss| if (ss.code) |c| c.deleter else null else null;
    if (deleter_cfg) |cfg| {
        const subs: []const settings_mod.Substitution = &.{
            .{ .key = "{file}", .value = file_path },
        };
        try runExternalTool(allocator, cfg, subs);
    } else {
        try builtinDelete(file_path);
    }

    const removed = removeFromIndex(allocator, file_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("deleted");
    try st.write(true);
    try st.objectField("index_updated");
    try st.write(removed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeRenameInner(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) ![]const u8 {
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    const renamer_cfg = if (s) |ss| if (ss.code) |c| c.renamer else null else null;
    if (renamer_cfg) |cfg| {
        const subs: []const settings_mod.Substitution = &.{
            .{ .key = "{old}", .value = old_path },
            .{ .key = "{new}", .value = new_path },
        };
        try runExternalTool(allocator, cfg, subs);
    } else {
        try builtinRename(old_path, new_path);
    }

    // Update index
    const cog_dir = paths.findCogDir(allocator) catch {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var st: Stringify = .{ .writer = &aw.writer };
        try st.beginObject();
        try st.objectField("old");
        try st.write(old_path);
        try st.objectField("new");
        try st.write(new_path);
        try st.objectField("renamed");
        try st.write(true);
        try st.objectField("reindexed");
        try st.write(false);
        try st.endObject();
        return aw.toOwnedSlice();
    };
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    removeDocument(allocator, &master_index, old_path);

    var reindexed = false;
    var reindex_backing: ?[]const u8 = null;
    var reindex_string_data: ?[]const u8 = null;
    defer if (reindex_backing) |data| allocator.free(data);
    defer if (reindex_string_data) |data| allocator.free(data);
    const ext_str = std.fs.path.extension(new_path);
    if (ext_str.len > 0) {
        if (extensions.resolveByExtension(allocator, ext_str)) |resolved| {
            defer extensions.freeExtension(allocator, &resolved);
            if (resolved.indexer) |idx| {
                switch (idx) {
                    .tree_sitter => |ts_config| {
                        if (readFileContents(allocator, new_path)) |source| {
                            defer allocator.free(source);
                            var indexer = tree_sitter_indexer.Indexer.init();
                            defer indexer.deinit();
                            if (indexer.indexFile(allocator, source, new_path, ts_config)) |result| {
                                reindex_string_data = result.string_data;
                                mergeDocument(allocator, &master_index, result.doc);
                                reindexed = true;
                            } else |_| {}
                        }
                    },
                    .scip_binary => |scip_config| {
                        if (invokeIndexerForFile(allocator, new_path, scip_config)) |file_result| {
                            reindex_backing = file_result.backing_data;
                            mergeDocument(allocator, &master_index, file_result.doc);
                            reindexed = true;
                        } else |_| {}
                    },
                }
            }
        }
    }
    _ = saveIndex(allocator, master_index, index_path, .{});

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("old");
    try st.write(old_path);
    try st.objectField("new");
    try st.write(new_path);
    try st.objectField("renamed");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeIndexInner(allocator: std.mem.Allocator, pattern_list: ?[]const []const u8) ![]const u8 {
    const index_start_ms = std.time.milliTimestamp();
    var patterns_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer patterns_buf.deinit(allocator);

    if (pattern_list) |pl| {
        for (pl) |p| try patterns_buf.append(allocator, p);
    }
    if (patterns_buf.items.len == 0) {
        try patterns_buf.append(allocator, "**/*");
    }

    const cog_dir = paths.findOrCreateCogDir(allocator) catch return error.NoCogDir;
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    std.fs.makeDirAbsolute(cog_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.MkdirFailed,
    };

    var backing_buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (backing_buffers.items) |buf| allocator.free(buf);
        backing_buffers.deinit(allocator);
    }

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    if (loaded.backing_data) |data| {
        backing_buffers.append(allocator, data) catch {};
    }

    const settings = settings_mod.Settings.load(allocator);
    defer if (settings) |s| s.deinit(allocator);
    const project_root = std.fs.path.dirname(cog_dir) orelse return error.NoCogDir;
    const external_roots = if (settings) |s|
        if (s.code) |code| code.external_roots orelse &.{} else &.{}
    else
        &.{};

    var files: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (files.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        files.deinit(allocator);
    }
    try collectMatchedFiles(allocator, project_root, patterns_buf.items, external_roots, &files);

    if (files.items.len == 0) return error.NoFilesMatched;
    debug_log.log("codeIndexInner: start patterns={d} matched_files={d}", .{ patterns_buf.items.len, files.items.len });
    debug_log.logResourceUsage("codeIndexInner:start");

    var indexed_count: usize = 0;
    var total_symbols: usize = 0;

    // Use an ArrayList for documents to avoid O(n²) reallocation
    var doc_list: std.ArrayListUnmanaged(scip.Document) = .empty;
    defer {
        for (doc_list.items) |*doc| scip.freeDocument(allocator, doc);
        doc_list.deinit(allocator);
    }
    try doc_list.ensureTotalCapacity(allocator, master_index.documents.len + files.items.len);
    doc_list.appendSliceAssumeCapacity(master_index.documents);
    if (master_index.documents.len > 0) allocator.free(master_index.documents);
    master_index.documents = &.{};

    var external_symbol_list: std.ArrayListUnmanaged(scip.SymbolInformation) = .empty;
    defer {
        for (external_symbol_list.items) |*sym| freeSymbolInformation(allocator, sym);
        external_symbol_list.deinit(allocator);
    }
    try external_symbol_list.ensureTotalCapacity(allocator, master_index.external_symbols.len);
    external_symbol_list.appendSliceAssumeCapacity(master_index.external_symbols);
    if (master_index.external_symbols.len > 0) allocator.free(master_index.external_symbols);
    master_index.external_symbols = &.{};

    var indexer = tree_sitter_indexer.Indexer.init();
    defer indexer.deinit();

    var seen_names: [16][]const u8 = undefined;
    var unique_exts: [16]extensions.Extension = undefined;
    var ext_files: [16]std.ArrayListUnmanaged([]const u8) = [_]std.ArrayListUnmanaged([]const u8){.empty} ** 16;
    // External indexers echo back the physical paths they were given, so the
    // logical alias each one belongs to has to be remembered here.
    var ext_mappings: [16]std.ArrayListUnmanaged(ExternalReindexPath) = [_]std.ArrayListUnmanaged(ExternalReindexPath){.empty} ** 16;
    var num_unique: usize = 0;

    // Cache extension resolution by file extension
    var ext_cache_keys: [32][]const u8 = undefined;
    var ext_cache_vals: [32]?extensions.Extension = undefined;
    var ext_cache_installed: [32]bool = [_]bool{false} ** 32;
    var ext_cache_len: usize = 0;
    defer for (0..ext_cache_len) |ci| {
        if (ext_cache_installed[ci]) {
            if (ext_cache_vals[ci]) |*val| extensions.freeExtension(allocator, val);
        }
    };

    for (files.items) |matched_file| {
        const file_path = matched_file.logical_path;
        const physical_path = matched_file.physical_path;
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) continue;

        const resolved = blk: {
            for (ext_cache_keys[0..ext_cache_len], ext_cache_vals[0..ext_cache_len]) |key, val| {
                if (std.mem.eql(u8, key, ext)) break :blk val;
            }
            const r = extensions.resolveByExtension(allocator, ext);
            if (ext_cache_len < 32) {
                ext_cache_keys[ext_cache_len] = ext;
                ext_cache_vals[ext_cache_len] = r;
                ext_cache_installed[ext_cache_len] = if (r) |v| v.installed else false;
                ext_cache_len += 1;
            }
            break :blk r;
        } orelse continue;

        const idx_config = resolved.indexer orelse continue;

        switch (idx_config) {
            .tree_sitter => |ts_config| {
                const file_start_ms = std.time.milliTimestamp();
                debug_log.log("codeIndexInner: tree_sitter:file_start path={s} grammar={s}", .{ file_path, ts_config.grammar_name });
                const source = readFileContents(allocator, physical_path) orelse continue;
                defer allocator.free(source);
                debug_log.log("codeIndexInner: tree_sitter:file_read path={s} bytes={d} elapsed_ms={d}", .{ file_path, source.len, std.time.milliTimestamp() - file_start_ms });
                if (indexer.indexFile(allocator, source, file_path, ts_config)) |result| {
                    backing_buffers.append(allocator, result.string_data) catch {};
                    mergeDocumentList(allocator, &doc_list, result.doc);
                    indexed_count += 1;
                    total_symbols += result.doc.symbols.len;
                    debug_log.log("codeIndexInner: tree_sitter:file_done path={s} symbols={d} occurrences={d} elapsed_ms={d}", .{ file_path, result.doc.symbols.len, result.doc.occurrences.len, std.time.milliTimestamp() - file_start_ms });
                } else |_| {
                    mergeDocumentList(allocator, &doc_list, .{
                        .language = ts_config.scip_name,
                        .relative_path = file_path,
                        .occurrences = &.{},
                        .symbols = &.{},
                    });
                    indexed_count += 1;
                    debug_log.log("codeIndexInner: tree_sitter:file_failed path={s} elapsed_ms={d}", .{ file_path, std.time.milliTimestamp() - file_start_ms });
                }
                debug_log.logResourceUsage("codeIndexInner:tree_sitter:file_done");
            },
            .scip_binary => {
                var found = false;
                var found_idx: usize = 0;
                for (seen_names[0..num_unique], 0..) |name, i| {
                    if (std.mem.eql(u8, name, resolved.name)) {
                        found = true;
                        found_idx = i;
                        break;
                    }
                }
                const mapping: ExternalReindexPath = .{
                    .logical_path = file_path,
                    .physical_path = physical_path,
                };
                if (!found and num_unique < 16) {
                    seen_names[num_unique] = resolved.name;
                    unique_exts[num_unique] = resolved;
                    ext_files[num_unique].append(allocator, physical_path) catch {};
                    ext_mappings[num_unique].append(allocator, mapping) catch {};
                    num_unique += 1;
                } else if (found) {
                    ext_files[found_idx].append(allocator, physical_path) catch {};
                    ext_mappings[found_idx].append(allocator, mapping) catch {};
                }
            },
        }
    }

    for (0..num_unique) |ext_idx| {
        const scip_config = switch (unique_exts[ext_idx].indexer orelse continue) {
            .scip_binary => |sc| sc,
            .tree_sitter => continue,
        };
        const batch_files = ext_files[ext_idx].items;
        if (batch_files.len == 0) continue;
        debug_log.log("codeIndexInner: invoking bulk external indexer {s} for {d} files", .{ scip_config.command, batch_files.len });
        debug_log.logResourceUsage("codeIndexInner:external:start");
        const result = invokeIndexerForFileList(allocator, batch_files, scip_config, null) catch |err| {
            debug_log.log("codeIndexInner: external batch failed command={s} files={d} error={s}", .{
                scip_config.command,
                batch_files.len,
                @errorName(err),
            });
            continue;
        };
        backing_buffers.append(allocator, result.backing_data.?) catch {};

        // Documents come back keyed by the physical paths the indexer was
        // given; the index is keyed by logical path, exactly as the
        // tree-sitter branch above already stores it.
        var remapped: std.ArrayListUnmanaged(scip.Document) = .empty;
        defer remapped.deinit(allocator);
        remapExternalDocuments(allocator, ext_mappings[ext_idx].items, result.index.documents, &remapped) catch {
            debug_log.log("codeIndexInner: alias remap failed command={s} docs={d}", .{
                scip_config.command,
                result.index.documents.len,
            });
            for (result.index.documents) |*doc| scip.freeDocument(allocator, doc);
            allocator.free(result.index.documents);
            for (result.index.external_symbols) |*sym| freeSymbolInformation(allocator, sym);
            allocator.free(result.index.external_symbols);
            continue;
        };
        for (remapped.items) |doc| {
            mergeDocumentList(allocator, &doc_list, doc);
            total_symbols += doc.symbols.len;
        }
        allocator.free(result.index.documents);
        for (result.index.external_symbols) |sym| {
            mergeExternalSymbolList(allocator, &external_symbol_list, sym);
        }
        allocator.free(result.index.external_symbols);
        indexed_count += batch_files.len;
        debug_log.log("codeIndexInner: external_done command={s} files={d} docs={d} external_symbols={d}", .{ scip_config.command, batch_files.len, result.index.documents.len, result.index.external_symbols.len });
        debug_log.logResourceUsage("codeIndexInner:external:done");
    }

    for (0..num_unique) |ext_idx| {
        ext_files[ext_idx].deinit(allocator);
        ext_mappings[ext_idx].deinit(allocator);
    }

    // Transfer documents back to master_index for encoding/freeing
    master_index.documents = try doc_list.toOwnedSlice(allocator);
    master_index.external_symbols = try external_symbol_list.toOwnedSlice(allocator);

    const encoded = scip_encode.encodeIndex(allocator, master_index) catch return error.EncodeFailed;
    defer allocator.free(encoded);

    if (!writeEncodedIndexAtomically(allocator, index_path, encoded)) return error.WriteFailed;
    writeManifestForIndex(allocator, index_path, master_index.documents, .{});

    total_symbols += master_index.external_symbols.len;

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("files_indexed");
    try st.write(indexed_count);
    try st.objectField("documents");
    try st.write(master_index.documents.len);
    try st.objectField("symbols");
    try st.write(total_symbols);
    try st.objectField("path");
    try st.write(index_path);
    try st.endObject();
    debug_log.log("codeIndexInner: done indexed={d} total_symbols={d} elapsed_ms={d}", .{ indexed_count, total_symbols, std.time.milliTimestamp() - index_start_ms });
    debug_log.logResourceUsage("codeIndexInner:done");
    return aw.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "CodeIndex.build and findSymbol" {
    const allocator = std.testing.allocator;

    // Construct an Index programmatically
    var occurrences = try allocator.alloc(scip.Occurrence, 2);
    defer allocator.free(occurrences);
    occurrences[0] = .{
        .range = .{ .start_line = 10, .start_char = 0, .end_line = 10, .end_char = 5 },
        .symbol = "pkg/Foo#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occurrences[1] = .{
        .range = .{ .start_line = 15, .start_char = 4, .end_line = 15, .end_char = 10 },
        .symbol = "pkg/Foo#bar().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    var doc_symbols = try allocator.alloc(scip.SymbolInformation, 2);
    defer allocator.free(doc_symbols);
    doc_symbols[0] = .{
        .symbol = "pkg/Foo#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49, // struct
        .display_name = "Foo",
        .enclosing_symbol = "",
    };
    doc_symbols[1] = .{
        .symbol = "pkg/Foo#bar().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 26, // method
        .display_name = "bar",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 1);
    documents[0] = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = occurrences,
        .symbols = doc_symbols,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "scip-go", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    var ci = try CodeIndex.build(allocator, index);
    defer {
        ci.symbol_to_defs.deinit(allocator);
        var ref_iter = ci.symbol_to_refs.iterator();
        while (ref_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        ci.symbol_to_refs.deinit(allocator);
        ci.path_to_doc_idx.deinit(allocator);
        allocator.free(ci.index.documents);
    }

    // Test findSymbol
    var matches = try ci.findSymbol(allocator, "Foo", null, null);
    defer matches.deinit(allocator);
    try std.testing.expect(matches.items.len > 0);
    try std.testing.expectEqualStrings("pkg/Foo#", matches.items[0].symbol);
    try std.testing.expectEqual(@as(i32, 10), matches.items[0].def.line);

    // Test findSymbol with kind filter
    var method_matches = try ci.findSymbol(allocator, "bar", "method", null);
    defer method_matches.deinit(allocator);
    try std.testing.expect(method_matches.items.len > 0);

    var struct_matches = try ci.findSymbol(allocator, "bar", "struct", null);
    defer struct_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), struct_matches.items.len);

    // Test path_to_doc_idx
    try std.testing.expect(ci.path_to_doc_idx.get("pkg/foo.go") != null);
    try std.testing.expect(ci.path_to_doc_idx.get("nonexistent.go") == null);
}

test "mergeDocument replaces existing document" {
    const allocator = std.testing.allocator;

    // Create initial index with one document
    var docs = try allocator.alloc(scip.Document, 1);
    docs[0] = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = &.{},
        .symbols = &.{},
    };

    var index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = docs,
        .external_symbols = &.{},
    };
    defer allocator.free(index.documents);

    // Merge a replacement document with same path
    const new_doc: scip.Document = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = &.{},
        .symbols = &.{},
    };
    mergeDocument(allocator, &index, new_doc);

    try std.testing.expectEqual(@as(usize, 1), index.documents.len);
    try std.testing.expectEqualStrings("pkg/foo.go", index.documents[0].relative_path);

    // Merge a new document with different path
    const another_doc: scip.Document = .{
        .language = "go",
        .relative_path = "pkg/bar.go",
        .occurrences = &.{},
        .symbols = &.{},
    };
    mergeDocument(allocator, &index, another_doc);

    try std.testing.expectEqual(@as(usize, 2), index.documents.len);
}

test "globMatch literal paths" {
    try std.testing.expect(globMatch("src/foo.ts", "src/foo.ts"));
    try std.testing.expect(!globMatch("src/foo.ts", "src/bar.ts"));
    try std.testing.expect(!globMatch("src/foo.ts", "src/foo.tsx"));
}

test "globMatch single star" {
    try std.testing.expect(globMatch("*.ts", "foo.ts"));
    try std.testing.expect(globMatch("*.ts", "bar.ts"));
    try std.testing.expect(!globMatch("*.ts", "foo.js"));
    try std.testing.expect(!globMatch("*.ts", "src/foo.ts")); // * does not cross /
    try std.testing.expect(globMatch("src/*.go", "src/main.go"));
    try std.testing.expect(!globMatch("src/*.go", "src/sub/main.go"));
}

test "globMatch double star" {
    try std.testing.expect(globMatch("**/*.ts", "foo.ts"));
    try std.testing.expect(globMatch("**/*.ts", "src/foo.ts"));
    try std.testing.expect(globMatch("**/*.ts", "src/sub/foo.ts"));
    try std.testing.expect(!globMatch("**/*.ts", "foo.js"));
    try std.testing.expect(globMatch("src/**/*.go", "src/main.go"));
    try std.testing.expect(globMatch("src/**/*.go", "src/pkg/main.go"));
    try std.testing.expect(globMatch("src/**/*.go", "src/pkg/sub/main.go"));
    try std.testing.expect(!globMatch("src/**/*.go", "lib/main.go"));
}

test "globMatch question mark" {
    try std.testing.expect(globMatch("?.ts", "a.ts"));
    try std.testing.expect(!globMatch("?.ts", "ab.ts"));
    try std.testing.expect(!globMatch("?.ts", "/.ts")); // ? does not match /
    try std.testing.expect(globMatch("src/?.go", "src/a.go"));
}

test "globMatch catch-all" {
    try std.testing.expect(globMatch("**/*", "foo.ts"));
    try std.testing.expect(globMatch("**/*", "src/foo.ts"));
    try std.testing.expect(globMatch("**/*", "src/sub/foo.ts"));
}

test "globPrefix extracts literal directory" {
    try std.testing.expectEqualStrings("src", globPrefix("src/**/*.ts"));
    try std.testing.expectEqualStrings(".", globPrefix("**/*.go"));
    try std.testing.expectEqualStrings("src", globPrefix("src/*.py"));
    try std.testing.expectEqualStrings(".", globPrefix("*.py"));
    try std.testing.expectEqualStrings("src", globPrefix("src/foo.ts")); // no wildcard, but prefix is src
}

test "negative glob helpers" {
    try std.testing.expect(isNegativeGlobPattern("!apps/**/priv/static/**"));
    try std.testing.expect(!isNegativeGlobPattern("apps/**/*.js"));
    try std.testing.expectEqualStrings("apps/**/priv/static/**", normalizeGlobPattern("!apps/**/priv/static/**"));
    try std.testing.expectEqualStrings("apps/**/*.js", normalizeGlobPattern("apps/**/*.js"));
}

test "collectMatchedFiles applies shared excludes and preserves symlink aliases" {
    const allocator = std.testing.allocator;
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();

    try root.dir.makePath("apps/foo/assets/js");
    try root.dir.makePath("apps/foo/priv/static/assets");

    try root.dir.writeFile(.{ .sub_path = "apps/foo/assets/js/app.js", .data = "console.log('src');\n" });
    try root.dir.writeFile(.{ .sub_path = "apps/foo/priv/static/assets/app.js", .data = "console.log('compiled');\n" });
    try root.dir.symLink("apps/foo/assets", "workspace-assets", .{ .is_directory = true });

    const cwd = std.fs.cwd();
    const original = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(original);
    const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{root.sub_path});
    defer allocator.free(tmp_root);
    try std.posix.chdir(tmp_root);
    defer std.posix.chdir(original) catch {};

    var files: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (files.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        files.deinit(allocator);
    }

    const project_root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(project_root);
    try collectMatchedFiles(allocator, project_root, &.{ "**/*.js", "!apps/**/priv/static/**" }, &.{}, &files);
    try std.testing.expectEqual(@as(usize, 2), files.items.len);
    try std.testing.expectEqualStrings("apps/foo/assets/js/app.js", files.items[0].logical_path);
    try std.testing.expectEqualStrings("workspace-assets/js/app.js", files.items[1].logical_path);
}

/// Build a document that owns its arrays, so tests exercise the same
/// ownership rules `scip.freeDocument` enforces on decoded documents.
fn testDocument(
    allocator: std.mem.Allocator,
    language: []const u8,
    relative_path: []const u8,
) !scip.Document {
    const occurrences = try allocator.alloc(scip.Occurrence, 1);
    errdefer allocator.free(occurrences);
    occurrences[0] = .{
        .range = .{ .start_line = 3, .start_char = 0, .end_line = 3, .end_char = 7 },
        .symbol = "pkg/Widget#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    const documentation = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(documentation);
    const relationships = try allocator.alloc(scip.Relationship, 0);
    errdefer allocator.free(relationships);

    const symbols = try allocator.alloc(scip.SymbolInformation, 1);
    symbols[0] = .{
        .symbol = "pkg/Widget#",
        .documentation = documentation,
        .relationships = relationships,
        .kind = 5,
        .display_name = "Widget",
        .enclosing_symbol = "",
    };

    return .{
        .language = language,
        .relative_path = relative_path,
        .occurrences = occurrences,
        .symbols = symbols,
    };
}

test "external documents fan out to every configured logical alias" {
    const allocator = std.testing.allocator;

    // One physical source is reachable under two logical names, a second is
    // reachable only through an external root, and the indexer also reports a
    // document nothing asked for.
    const mappings = [_]ExternalReindexPath{
        .{ .logical_path = "src/main.rb", .physical_path = "/project/src/main.rb" },
        .{ .logical_path = "src-link/main.rb", .physical_path = "/project/src/main.rb" },
        .{ .logical_path = "@external/shared/lib.rb", .physical_path = "/shared/lib.rb" },
    };

    var documents = [_]scip.Document{
        try testDocument(allocator, "ruby", "/project/src/main.rb"),
        try testDocument(allocator, "ruby", "/shared/lib.rb"),
        try testDocument(allocator, "ruby", "vendor/bundle/rack.rb"),
    };

    var out: std.ArrayListUnmanaged(scip.Document) = .empty;
    defer {
        for (out.items) |*doc| scip.freeDocument(allocator, doc);
        out.deinit(allocator);
    }
    try remapExternalDocuments(allocator, &mappings, &documents, &out);

    // Every configured alias keeps its own document, matching how tree-sitter
    // documents are already keyed by logical path.
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("src/main.rb", out.items[0].relative_path);
    try std.testing.expectEqualStrings("src-link/main.rb", out.items[1].relative_path);
    try std.testing.expectEqualStrings("@external/shared/lib.rb", out.items[2].relative_path);

    // A document the indexer generated for a dependency is not ours to
    // rename, so it passes through untouched.
    try std.testing.expectEqualStrings("vendor/bundle/rack.rb", out.items[3].relative_path);

    // Each alias owns its own arrays: freeing all four documents in the
    // deferred cleanup above must not double-free the shared source.
    try std.testing.expect(out.items[0].occurrences.ptr != out.items[1].occurrences.ptr);
    try std.testing.expect(out.items[0].symbols.ptr != out.items[1].symbols.ptr);
    try std.testing.expectEqual(
        out.items[0].occurrences[0].range.start_line,
        out.items[1].occurrences[0].range.start_line,
    );
    try std.testing.expectEqualStrings(
        out.items[0].symbols[0].display_name,
        out.items[1].symbols[0].display_name,
    );
}

fn findBatchEntry(batch: []const ReindexPath, logical_path: []const u8) ?ReindexPath {
    for (batch) |entry| {
        if (std.mem.eql(u8, entry.logical_path, logical_path)) return entry;
    }
    return null;
}

test "configured reconciliation converges on the managed source set" {
    const allocator = std.testing.allocator;

    const matched = [_]path_matcher.MatchedPath{
        .{ .logical_path = "src/main.zig", .physical_path = "/project/src/main.zig" },
        .{ .logical_path = "@external/shared/lib.zig", .physical_path = "/shared/lib.zig" },
    };
    const documents = [_]scip.Document{
        // Still matched: refreshed from its physical source.
        .{ .language = "zig", .relative_path = "src/main.zig", .occurrences = &.{}, .symbols = &.{} },
        // Managed but no longer matched because the pattern narrowed.
        .{ .language = "zig", .relative_path = "src/legacy.zig", .occurrences = &.{}, .symbols = &.{} },
        // Excluded by a negative pattern, still inside the managed space.
        .{ .language = "zig", .relative_path = "src/generated/skip.zig", .occurrences = &.{}, .symbols = &.{} },
        // An external alias the settings no longer configure.
        .{ .language = "zig", .relative_path = "@external/dropped/old.zig", .occurrences = &.{}, .symbols = &.{} },
        // Dependency-generated: the indexer walked into these on its own, and
        // no configured pattern can ever reproduce them.
        .{ .language = "typescript", .relative_path = "node_modules/@types/node/index.d.ts", .occurrences = &.{}, .symbols = &.{} },
        .{ .language = "ruby", .relative_path = "/usr/lib/ruby/3.4/set.rb", .occurrences = &.{}, .symbols = &.{} },
    };

    var batch: std.ArrayListUnmanaged(ReindexPath) = .empty;
    defer batch.deinit(allocator);
    try appendConfiguredReindexPaths(allocator, &matched, &documents, &batch);

    // Two matched sources plus three managed removals — and nothing else.
    try std.testing.expectEqual(@as(usize, 5), batch.items.len);

    const main_entry = findBatchEntry(batch.items, "src/main.zig") orelse
        return error.MissingMatchedSource;
    try std.testing.expectEqualStrings("/project/src/main.zig", main_entry.physical_path.?);
    const external_entry = findBatchEntry(batch.items, "@external/shared/lib.zig") orelse
        return error.MissingMatchedSource;
    try std.testing.expectEqualStrings("/shared/lib.zig", external_entry.physical_path.?);

    // A null physical path is how the batch spells "remove this document".
    for ([_][]const u8{ "src/legacy.zig", "src/generated/skip.zig", "@external/dropped/old.zig" }) |stale| {
        const entry = findBatchEntry(batch.items, stale) orelse return error.MissingStaleRemoval;
        try std.testing.expect(entry.physical_path == null);
    }

    // Deleting these would throw away cross-repository symbols that no
    // configured pattern can rebuild.
    try std.testing.expect(findBatchEntry(batch.items, "node_modules/@types/node/index.d.ts") == null);
    try std.testing.expect(findBatchEntry(batch.items, "/usr/lib/ruby/3.4/set.rb") == null);
}

test "configured reconciliation retains physical reads and removes stale aliases" {
    const allocator = std.testing.allocator;
    const matched = [_]path_matcher.MatchedPath{
        .{ .logical_path = "src/main.zig", .physical_path = "/project/src/main.zig" },
        .{ .logical_path = "@external/shared/lib.zig", .physical_path = "/shared/lib.zig" },
    };
    const documents = [_]scip.Document{
        .{ .language = "zig", .relative_path = "src/main.zig", .occurrences = &.{}, .symbols = &.{} },
        .{ .language = "zig", .relative_path = "old/generated.zig", .occurrences = &.{}, .symbols = &.{} },
    };

    var batch: std.ArrayListUnmanaged(ReindexPath) = .empty;
    defer batch.deinit(allocator);
    try appendConfiguredReindexPaths(allocator, &matched, &documents, &batch);

    try std.testing.expectEqual(@as(usize, 3), batch.items.len);
    try std.testing.expectEqualStrings("src/main.zig", batch.items[0].logical_path);
    try std.testing.expectEqualStrings("/project/src/main.zig", batch.items[0].physical_path.?);
    try std.testing.expectEqualStrings("@external/shared/lib.zig", batch.items[1].logical_path);
    try std.testing.expectEqualStrings("/shared/lib.zig", batch.items[1].physical_path.?);
    try std.testing.expectEqualStrings("old/generated.zig", batch.items[2].logical_path);
    try std.testing.expect(batch.items[2].physical_path == null);
}

test "watcher reindex batch maps logical aliases onto their physical sources" {
    const allocator = std.testing.allocator;
    // Two logical aliases deliberately share one physical source, and one
    // alias is reachable only through an external root.
    const matched = [_]path_matcher.MatchedPath{
        .{ .logical_path = "@external/shared/lib.zig", .physical_path = "/shared/lib.zig" },
        .{ .logical_path = "src/main.zig", .physical_path = "/project/src/main.zig" },
        .{ .logical_path = "src-link/main.zig", .physical_path = "/project/src/main.zig" },
    };
    const logical_paths = [_][]const u8{
        "@external/shared/lib.zig",
        "src/main.zig",
        "src-link/main.zig",
        "removed/gone.zig",
    };

    var batch: std.ArrayListUnmanaged(ReindexPath) = .empty;
    defer batch.deinit(allocator);
    try appendAliasedReindexPaths(allocator, &logical_paths, &matched, &batch);

    try std.testing.expectEqual(@as(usize, 4), batch.items.len);

    // An @external alias must read its physical source instead of being
    // treated as a missing file and dropped from the index.
    try std.testing.expectEqualStrings("@external/shared/lib.zig", batch.items[0].logical_path);
    try std.testing.expectEqualStrings("/shared/lib.zig", batch.items[0].physical_path.?);

    // Both aliases keep their own logical document name while reading the
    // single physical source they share.
    try std.testing.expectEqualStrings("src/main.zig", batch.items[1].logical_path);
    try std.testing.expectEqualStrings("/project/src/main.zig", batch.items[1].physical_path.?);
    try std.testing.expectEqualStrings("src-link/main.zig", batch.items[2].logical_path);
    try std.testing.expectEqualStrings("/project/src/main.zig", batch.items[2].physical_path.?);

    // An unmatched path falls back to itself so the existence check still
    // resolves it as a removal.
    try std.testing.expectEqualStrings("removed/gone.zig", batch.items[3].logical_path);
    try std.testing.expectEqualStrings("removed/gone.zig", batch.items[3].physical_path.?);
}

test "collectConfiguredFiles uses PathMatcher logical paths and external roots" {
    const allocator = std.testing.allocator;
    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    var external = std.testing.tmpDir(.{});
    defer external.cleanup();

    try project.dir.makePath("src/generated");
    try project.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    try project.dir.writeFile(.{ .sub_path = "src/generated/skip.zig", .data = "const skip = true;\n" });
    try external.dir.writeFile(.{ .sub_path = "shared.zig", .data = "pub const shared = true;\n" });

    const external_root = try external.dir.realpathAlloc(allocator, ".");
    defer allocator.free(external_root);
    try project.dir.symLink("src", "src-link", .{ .is_directory = true });
    try project.dir.symLink(external_root, "shared-link", .{ .is_directory = true });

    const project_root = try project.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);
    var files: std.ArrayListUnmanaged(path_matcher.MatchedPath) = .empty;
    defer {
        for (files.items) |file| {
            allocator.free(file.logical_path);
            allocator.free(file.physical_path);
        }
        files.deinit(allocator);
    }

    try collectConfiguredFiles(
        allocator,
        project_root,
        &.{ "**/*.zig", "!**/generated/**" },
        &.{external_root},
        &files,
    );

    var saw_main = false;
    var saw_project_alias = false;
    var saw_external_alias = false;
    var saw_direct_external = false;
    for (files.items) |file| {
        if (std.mem.eql(u8, file.logical_path, "src/main.zig")) saw_main = true;
        if (std.mem.eql(u8, file.logical_path, "src-link/main.zig")) saw_project_alias = true;
        if (std.mem.eql(u8, file.logical_path, "shared-link/shared.zig")) saw_external_alias = true;
        if (std.mem.startsWith(u8, file.logical_path, "@external/") and
            std.mem.endsWith(u8, file.logical_path, "/shared.zig")) saw_direct_external = true;
        try std.testing.expect(std.mem.indexOf(u8, file.logical_path, "generated") == null);
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_project_alias);
    try std.testing.expect(saw_external_alias);
    try std.testing.expect(saw_direct_external);
}

/// Test allocator that poisons freed memory with 0xAA and retains the pages
/// until `deinit`, so a use-after-free surfaces as deterministic garbage bytes
/// instead of an unmapped-page segfault. Retained blocks are released to the
/// child allocator on `deinit`, so `std.testing.allocator` still sees a
/// balanced alloc/free ledger and can report genuine leaks.
const PoisonRetainingAllocator = struct {
    child: std.mem.Allocator,
    retained: std.ArrayListUnmanaged(Block) = .empty,

    const Block = struct {
        ptr: [*]u8,
        len: usize,
        alignment: std.mem.Alignment,
    };

    fn allocator(self: *PoisonRetainingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = poisonAlloc,
                .resize = poisonResize,
                .remap = poisonRemap,
                .free = poisonFree,
            },
        };
    }

    fn deinit(self: *PoisonRetainingAllocator) void {
        for (self.retained.items) |block| {
            self.child.rawFree(block.ptr[0..block.len], block.alignment, @returnAddress());
        }
        self.retained.deinit(self.child);
    }

    fn poisonAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonRetainingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn poisonResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn poisonRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn poisonFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        const self: *PoisonRetainingAllocator = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xAA);
        self.retained.append(self.child, .{
            .ptr = memory.ptr,
            .len = memory.len,
            .alignment = alignment,
        }) catch @panic("poison allocator failed to retain freed block");
    }
};

fn expectUnpoisoned(text: []const u8) !void {
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0xAA) == null);
}

test "reindexFiles keeps indexed string storage alive through index encoding" {
    var poison: PoisonRetainingAllocator = .{ .child = std.testing.allocator };
    defer poison.deinit();
    const allocator = poison.allocator();

    var project = std.testing.tmpDir(.{});
    defer project.cleanup();
    try project.dir.makePath(".cog");
    try project.dir.writeFile(.{
        .sub_path = "widget.go",
        .data =
        \\package sample
        \\
        \\type Widget struct {
        \\    Value int
        \\}
        \\
        \\func (item Widget) Compute() int {
        \\    return item.Value
        \\}
        \\
        ,
    });

    const original = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(original);
    const tmp_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{project.sub_path});
    defer std.testing.allocator.free(tmp_root);
    try std.posix.chdir(tmp_root);
    defer std.posix.chdir(original) catch {};

    try std.testing.expect(reindexFiles(allocator, &.{"widget.go"}));

    const encoded = try std.fs.cwd().readFileAlloc(std.testing.allocator, ".cog/index.scip", 16 * 1024 * 1024);
    defer std.testing.allocator.free(encoded);
    var index = try scip.decode(std.testing.allocator, encoded);
    defer scip.freeIndex(std.testing.allocator, &index);

    try std.testing.expectEqual(@as(usize, 1), index.documents.len);
    const doc = index.documents[0];
    try std.testing.expectEqualStrings("widget.go", doc.relative_path);
    try std.testing.expect(doc.symbols.len > 0);

    // Symbol ids ("local N") and display names are both slices into the
    // tree-sitter string buffer, so a freed buffer shows up as poison here.
    var saw_widget = false;
    var saw_compute = false;
    for (doc.symbols) |symbol| {
        try expectUnpoisoned(symbol.symbol);
        try expectUnpoisoned(symbol.display_name);
        if (std.mem.eql(u8, symbol.display_name, "Widget")) saw_widget = true;
        if (std.mem.eql(u8, symbol.display_name, "Compute")) saw_compute = true;
    }
    for (doc.occurrences) |occurrence| {
        try expectUnpoisoned(occurrence.symbol);
    }
    try std.testing.expect(saw_widget);
    try std.testing.expect(saw_compute);
}

test "pathIsTest" {
    try std.testing.expect(CodeIndex.pathIsTest("src/__tests__/foo.js"));
    try std.testing.expect(CodeIndex.pathIsTest("src/test/main.go"));
    try std.testing.expect(CodeIndex.pathIsTest("lib/foo.test.ts"));
    try std.testing.expect(CodeIndex.pathIsTest("lib/foo.spec.js"));
    try std.testing.expect(CodeIndex.pathIsTest("main_test.go"));
    try std.testing.expect(!CodeIndex.pathIsTest("src/main.go"));
    try std.testing.expect(!CodeIndex.pathIsTest("lib/component.js"));
}

test "countPathSeparators" {
    try std.testing.expectEqual(@as(usize, 0), CodeIndex.countPathSeparators("main.go"));
    try std.testing.expectEqual(@as(usize, 1), CodeIndex.countPathSeparators("src/main.go"));
    try std.testing.expectEqual(@as(usize, 2), CodeIndex.countPathSeparators("src/pkg/main.go"));
    try std.testing.expectEqual(@as(usize, 3), CodeIndex.countPathSeparators("a/b/c/d.go"));
}

test "EnclosingRangeIndex finds innermost definitions with bounded lookup" {
    const allocator = std.testing.allocator;
    const entry_count: usize = 1_025;
    const target_index: usize = 800;
    const target_line: i32 = @intCast(target_index * 2);

    var entries: [entry_count]EnclosingRangeEntry = undefined;
    entries[0] = .{
        .symbol = "outer",
        .range = .{ .start_line = 0, .start_char = 0, .end_line = 3_000, .end_char = 0 },
        .document_order = 0,
    };
    for (1..entry_count) |i| {
        const start_line: i32 = @intCast(i * 2);
        entries[i] = .{
            .symbol = if (i == target_index) "target" else "sibling",
            .range = .{ .start_line = start_line, .start_char = 0, .end_line = start_line + 1, .end_char = 0 },
            .document_order = i,
        };
    }

    var range_index = try EnclosingRangeIndex.init(allocator, &entries);
    defer range_index.deinit(allocator);

    var probes: usize = 0;
    const target = range_index.findInnermostCounted(target_line, 0, &probes) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("target", target);
    try std.testing.expect(probes <= 64);

    probes = 0;
    const gap = range_index.findInnermostCounted(target_line + 1, 1, &probes) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("outer", gap);
    try std.testing.expect(probes <= 64);
}

test "EnclosingRangeIndex preserves innermost tie behavior" {
    const allocator = std.testing.allocator;
    const entries = [_]EnclosingRangeEntry{
        .{ .symbol = "outer", .range = .{ .start_line = 0, .start_char = 0, .end_line = 100, .end_char = 0 }, .document_order = 0 },
        .{ .symbol = "same-start-outer", .range = .{ .start_line = 10, .start_char = 0, .end_line = 20, .end_char = 0 }, .document_order = 1 },
        .{ .symbol = "same-start-inner", .range = .{ .start_line = 10, .start_char = 0, .end_line = 15, .end_char = 0 }, .document_order = 2 },
        .{ .symbol = "same-range-later", .range = .{ .start_line = 10, .start_char = 0, .end_line = 15, .end_char = 0 }, .document_order = 3 },
    };

    var range_index = try EnclosingRangeIndex.init(allocator, &entries);
    defer range_index.deinit(allocator);

    const found = range_index.findInnermost(12, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("same-range-later", found);
}

test "index writes refresh the provenance manifest for managed documents" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir(".cog");
    try tmp.dir.writeFile(.{ .sub_path = "tracked.zig", .data = "const tracked = 1;\n" });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const index_path = try std.fs.path.join(allocator, &.{ root, ".cog", "index.scip" });
    defer allocator.free(index_path);

    try tmp.dir.writeFile(.{ .sub_path = "external-dep.zig", .data = "const dep = 2;\n" });
    const dep_physical = try tmp.dir.realpathAlloc(allocator, "external-dep.zig");
    defer allocator.free(dep_physical);

    var documents = [_]scip.Document{
        .{ .language = "zig", .relative_path = "tracked.zig", .occurrences = &.{}, .symbols = &.{} },
        // Deleted files must not appear; external aliases stat through their
        // physical location.
        .{ .language = "zig", .relative_path = "deleted.zig", .occurrences = &.{}, .symbols = &.{} },
        .{ .language = "zig", .relative_path = "@external/lib/dep.zig", .occurrences = &.{}, .symbols = &.{} },
    };
    const aliases = [_]path_matcher.MatchedPath{
        .{ .logical_path = "@external/lib/dep.zig", .physical_path = dep_physical },
    };
    writeManifestForIndex(allocator, index_path, &documents, .{ .aliases = &aliases });

    var cog_dir = try tmp.dir.openDir(".cog", .{});
    defer cog_dir.close();
    var loaded = index_manifest.load(allocator, cog_dir) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.value.entries.len);
    try std.testing.expectEqualStrings("tracked.zig", loaded.value.entries[0].path);
    try std.testing.expectEqual(@as(u64, 19), loaded.value.entries[0].size);
    try std.testing.expectEqualStrings("@external/lib/dep.zig", loaded.value.entries[1].path);
    try std.testing.expectEqual(@as(u64, 15), loaded.value.entries[1].size);
}

test "shouldFullResync escalates on missing manifest and large drift" {
    try std.testing.expect(shouldFullResync(true, 0, 0, 10));
    try std.testing.expect(!shouldFullResync(false, 4, 0, 10));
    try std.testing.expect(shouldFullResync(false, 5, 0, 10));
    try std.testing.expect(shouldFullResync(false, 0, 5, 10));
    try std.testing.expect(!shouldFullResync(false, 0, 0, 0));
    try std.testing.expect(shouldFullResync(false, 1, 0, 0));
}

test "syncConfiguredFiles repairs drift and converges" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.writeFile(.{ .sub_path = ".cog/settings.json", .data = 
        \\{
        \\  "code": {
        \\    "index": ["**/*.go"]
        \\  }
        \\}
    });
    const names = [_][]const u8{ "a.go", "b.go", "c.go", "d.go", "e.go", "f.go" };
    for (names, 0..) |name, i| {
        var buffer: [96]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "package p\n\nfunc F{d}() int {{ return {d} }}\n", .{ i, i });
        try tmp.dir.writeFile(.{ .sub_path = name, .data = source });
    }
    try tmp.dir.setAsCwd();

    try std.testing.expect(reindexConfiguredFiles(allocator));

    // Nothing drifted: the scan must not touch the index.
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);

    // One modified plus one added is 2 of 7 matched files — small drift
    // takes the targeted batch path, not a full resync.
    try tmp.dir.writeFile(.{ .sub_path = "b.go", .data = "package p\n\nfunc F1() int { return 100 }\n\nfunc Extra() int { return 7 }\n" });
    try tmp.dir.writeFile(.{ .sub_path = "g.go", .data = "package p\n\nfunc G() int { return 9 }\n" });

    const repaired = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, repaired.outcome);
    try std.testing.expectEqual(@as(usize, 2), repaired.changed);
    try std.testing.expectEqual(@as(usize, 0), repaired.removed);
    try std.testing.expect(!repaired.full_resync);

    // A deletion alone is 1 of 6 — also targeted, and it must drop the
    // document rather than reindex anything.
    try tmp.dir.deleteFile("a.go");
    const pruned = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, pruned.outcome);
    try std.testing.expectEqual(@as(usize, 0), pruned.changed);
    try std.testing.expectEqual(@as(usize, 1), pruned.removed);
    try std.testing.expect(!pruned.full_resync);

    // The manifest mirrors the repaired document set.
    var cog_dir = try tmp.dir.openDir(".cog", .{});
    defer cog_dir.close();
    {
        var loaded = index_manifest.load(allocator, cog_dir) orelse return error.TestUnexpectedResult;
        defer loaded.deinit();
        var saw_g = false;
        for (loaded.value.entries) |entry| {
            try std.testing.expect(!std.mem.eql(u8, entry.path, "a.go"));
            if (std.mem.eql(u8, entry.path, "g.go")) saw_g = true;
        }
        try std.testing.expect(saw_g);
    }

    // Convergence: a second reconcile finds nothing to do.
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);

    // Unknown provenance escalates to a full resync and self-heals.
    try cog_dir.deleteFile(index_manifest.manifest_basename);
    const rebuilt = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, rebuilt.outcome);
    try std.testing.expect(rebuilt.full_resync);
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);

    // Drift reporting without repair leaves the drift in place.
    try tmp.dir.writeFile(.{ .sub_path = "c.go", .data = "package p\n\nfunc F2() int { return 200 }\n\nfunc More() int { return 8 }\n" });
    const scanned = scanConfiguredDrift(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, scanned.outcome);
    try std.testing.expectEqual(@as(usize, 1), scanned.changed);
    try std.testing.expectEqual(SyncOutcome.changed, scanConfiguredDrift(allocator).outcome);
    try std.testing.expectEqual(SyncOutcome.changed, syncConfiguredFiles(allocator).outcome);
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);
}

test "syncConfiguredFiles works from manifest-recorded patterns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.writeFile(.{ .sub_path = ".cog/settings.json", .data = 
        \\{
        \\  "code": {
        \\    "index": ["**/*.go"]
        \\  }
        \\}
    });
    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = "package p\n\nfunc A() int { return 1 }\n" });
    try tmp.dir.setAsCwd();

    try std.testing.expect(reindexConfiguredFiles(allocator));

    // Without a settings pattern entry the recorded manifest patterns keep
    // reconciliation working — the ad-hoc indexing case.
    try tmp.dir.deleteFile(".cog/settings.json");
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);

    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = "package p\n\nfunc A() int { return 1 }\n\nfunc B() int { return 2 }\n" });
    const repaired = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, repaired.outcome);
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);
}

test "content hashes rescue mtime churn and catch same-size edits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.writeFile(.{ .sub_path = ".cog/settings.json", .data = 
        \\{
        \\  "code": {
        \\    "index": ["**/*.go"]
        \\  }
        \\}
    });
    const body = "package p\n\nfunc A() int { return 100 }\n";
    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = body });
    try tmp.dir.setAsCwd();

    try std.testing.expect(reindexConfiguredFiles(allocator));

    // Rewriting identical bytes moves the mtime — checkout churn. The hash
    // confirmation must classify it as clean, and the manifest refresh must
    // make the next scan cheap again.
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = body });
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);

    // A same-size content change must still be caught.
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = "package p\n\nfunc A() int { return 200 }\n" });
    const repaired = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, repaired.outcome);
    try std.testing.expectEqual(@as(usize, 1), repaired.changed);
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);
}

fn runGitForTest(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const run = std.process.Child.run(.{ .allocator = allocator, .argv = argv, .cwd = cwd }) catch return error.SkipZigTest;
    allocator.free(run.stdout);
    allocator.free(run.stderr);
    switch (run.term) {
        .Exited => |code| if (code != 0) return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    }
}

test "git candidate fast path repairs drift without walking" {
    const allocator = std.testing.allocator;

    const probe = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "--version" } }) catch return error.SkipZigTest;
    allocator.free(probe.stdout);
    allocator.free(probe.stderr);
    switch (probe.term) {
        .Exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.writeFile(.{ .sub_path = ".cog/settings.json", .data = 
        \\{
        \\  "code": {
        \\    "index": ["**/*.go"]
        \\  }
        \\}
    });
    const names = [_][]const u8{ "a.go", "b.go", "c.go", "d.go", "e.go", "f.go" };
    for (names, 0..) |name, i| {
        var buffer: [96]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "package p\n\nfunc F{d}() int {{ return {d} }}\n", .{ i, i });
        try tmp.dir.writeFile(.{ .sub_path = name, .data = source });
    }
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    try runGitForTest(allocator, root, &.{ "git", "init" });
    try runGitForTest(allocator, root, &.{ "git", "add", "-A" });
    try runGitForTest(allocator, root, &.{
        "git", "-c", "user.email=cog@test", "-c", "user.name=cog", "-c", "commit.gpgsign=false", "commit", "-m", "init",
    });
    try tmp.dir.setAsCwd();

    try std.testing.expect(reindexConfiguredFiles(allocator));

    const saved_threshold = git_fast_path_min_entries;
    git_fast_path_min_entries = 0;
    defer git_fast_path_min_entries = saved_threshold;

    // A worktree edit and an untracked file surface through git status.
    try tmp.dir.writeFile(.{ .sub_path = "b.go", .data = "package p\n\nfunc F1() int { return 100 }\n\nfunc Extra() int { return 7 }\n" });
    try tmp.dir.writeFile(.{ .sub_path = "g.go", .data = "package p\n\nfunc G() int { return 9 }\n" });
    const repaired = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, repaired.outcome);
    try std.testing.expectEqual(@as(usize, 2), repaired.changed);
    try std.testing.expectEqual(@as(usize, 0), repaired.removed);
    try std.testing.expect(!repaired.full_resync);

    // A deletion surfaces as a candidate whose file is gone.
    try tmp.dir.deleteFile("a.go");
    const pruned = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, pruned.outcome);
    try std.testing.expectEqual(@as(usize, 0), pruned.changed);
    try std.testing.expectEqual(@as(usize, 1), pruned.removed);
    try std.testing.expect(!pruned.full_resync);

    // Persistent worktree dirt stays a candidate but proves clean.
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);
}

test "syncConfiguredFiles converges for external roots" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makePath("proj/.cog");
    try tmp.dir.makePath("ext");
    try tmp.dir.writeFile(.{ .sub_path = "ext/lib.go", .data = "package ext\n\nfunc Lib() int { return 1 }\n" });
    const ext_root = try tmp.dir.realpathAlloc(allocator, "ext");
    defer allocator.free(ext_root);

    const settings_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "code": {{
        \\    "index": ["**/*.go"],
        \\    "external_roots": ["{s}"]
        \\  }}
        \\}}
    , .{ext_root});
    defer allocator.free(settings_json);
    try tmp.dir.writeFile(.{ .sub_path = "proj/.cog/settings.json", .data = settings_json });

    const names = [_][]const u8{ "a.go", "b.go", "c.go", "d.go" };
    for (names, 0..) |name, i| {
        var buffer: [96]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "package p\n\nfunc F{d}() int {{ return {d} }}\n", .{ i, i });
        var proj = try tmp.dir.openDir("proj", .{});
        defer proj.close();
        try proj.writeFile(.{ .sub_path = name, .data = source });
    }

    var proj_dir = try tmp.dir.openDir("proj", .{});
    defer proj_dir.close();
    try proj_dir.setAsCwd();

    try std.testing.expect(reindexConfiguredFiles(allocator));

    // External-root documents must have manifest entries statted through
    // their physical paths, or every reconcile reports them drifted.
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);

    // An edit under the external root is real drift.
    try tmp.dir.writeFile(.{ .sub_path = "ext/lib.go", .data = "package ext\n\nfunc Lib() int { return 2 }\n\nfunc More() int { return 3 }\n" });
    const repaired = syncConfiguredFiles(allocator);
    try std.testing.expectEqual(SyncOutcome.changed, repaired.outcome);
    try std.testing.expectEqual(@as(usize, 1), repaired.changed);
    try std.testing.expectEqual(SyncOutcome.unchanged, syncConfiguredFiles(allocator).outcome);
}

test "set-based relationship and import dedup preserves first-seen order" {
    const allocator = std.testing.allocator;

    var relationship_seen: RelationshipDedupSet = .empty;
    defer relationship_seen.deinit(allocator);
    var relationships: RelationshipList = .empty;
    defer relationships.deinit(allocator);

    const relationship_inputs = [_]RelationshipInfo{
        .{ .symbol = "alpha", .kind = "calls" },
        .{ .symbol = "beta", .kind = "implements" },
        .{ .symbol = "alpha", .kind = "calls" },
        .{ .symbol = "gamma", .kind = "calls" },
    };
    for (0..4_096) |i| {
        try appendDeduplicatedRelationship(
            allocator,
            &relationship_seen,
            "owner",
            &relationships,
            relationship_inputs[i % relationship_inputs.len],
        );
    }

    try std.testing.expectEqual(@as(usize, 3), relationships.items.len);
    try std.testing.expectEqual(@as(usize, 3), relationship_seen.count());
    try std.testing.expectEqualStrings("alpha", relationships.items[0].symbol);
    try std.testing.expectEqualStrings("beta", relationships.items[1].symbol);
    try std.testing.expectEqualStrings("gamma", relationships.items[2].symbol);

    var import_seen: ImportDedupSet = .empty;
    defer import_seen.deinit(allocator);
    var imports: FileImportList = .empty;
    defer imports.deinit(allocator);

    const import_inputs = [_]FileImport{
        .{ .label = "src/a.zig", .symbol = "cog/import/src/a.zig" },
        .{ .label = "src/b.zig", .symbol = "cog/import/src/b.zig" },
        .{ .label = "src/a.zig", .symbol = "cog/import/src/a.zig" },
        .{ .label = "src/c.zig", .symbol = "cog/import/src/c.zig" },
    };
    for (0..4_096) |i| {
        try appendDeduplicatedImport(
            allocator,
            &import_seen,
            "src/main.zig",
            &imports,
            import_inputs[i % import_inputs.len],
        );
    }

    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    try std.testing.expectEqual(@as(usize, 3), import_seen.count());
    try std.testing.expectEqualStrings("src/a.zig", imports.items[0].label);
    try std.testing.expectEqualStrings("src/b.zig", imports.items[1].label);
    try std.testing.expectEqualStrings("src/c.zig", imports.items[2].label);
}

test "sortMatchesByScore" {
    const allocator = std.testing.allocator;
    var matches: CodeIndex.MatchList = .empty;
    defer matches.deinit(allocator);
    try matches.append(allocator, .{ .symbol = "a", .def = .{ .path = "a.go", .line = 0, .kind = 0, .display_name = "a", .documentation = &.{} }, .score = 10 });
    try matches.append(allocator, .{ .symbol = "b", .def = .{ .path = "b.go", .line = 0, .kind = 0, .display_name = "b", .documentation = &.{} }, .score = 50 });
    try matches.append(allocator, .{ .symbol = "c", .def = .{ .path = "c.go", .line = 0, .kind = 0, .display_name = "c", .documentation = &.{} }, .score = 30 });

    CodeIndex.sortMatchesByScore(&matches);

    try std.testing.expectEqual(@as(u8, 50), matches.items[0].score);
    try std.testing.expectEqual(@as(u8, 30), matches.items[1].score);
    try std.testing.expectEqual(@as(u8, 10), matches.items[2].score);
}

test "nameGlobMatch" {
    // Exact match (case insensitive)
    try std.testing.expect(nameGlobMatch("Foo", "Foo"));
    try std.testing.expect(nameGlobMatch("foo", "Foo"));
    try std.testing.expect(nameGlobMatch("FOO", "foo"));

    // Star wildcard
    try std.testing.expect(nameGlobMatch("*init*", "initServer"));
    try std.testing.expect(nameGlobMatch("*init*", "serverInit"));
    try std.testing.expect(nameGlobMatch("*init*", "myInitFunc"));
    try std.testing.expect(nameGlobMatch("*init*", "init"));
    try std.testing.expect(!nameGlobMatch("*init*", "configure"));

    // Prefix/suffix patterns
    try std.testing.expect(nameGlobMatch("get*", "getUser"));
    try std.testing.expect(nameGlobMatch("get*", "Get"));
    try std.testing.expect(!nameGlobMatch("get*", "forget"));
    try std.testing.expect(nameGlobMatch("*Handler", "RequestHandler"));
    try std.testing.expect(!nameGlobMatch("*Handler", "handle"));

    // Question mark
    try std.testing.expect(nameGlobMatch("?oo", "Foo"));
    try std.testing.expect(nameGlobMatch("?oo", "foo"));
    try std.testing.expect(!nameGlobMatch("?oo", "Fooo"));

    // Match-all
    try std.testing.expect(nameGlobMatch("*", "anything"));
    try std.testing.expect(nameGlobMatch("*", ""));
}

test "hasGlobChars" {
    try std.testing.expect(hasGlobChars("*init*"));
    try std.testing.expect(hasGlobChars("foo?"));
    try std.testing.expect(hasGlobChars("get*"));
    try std.testing.expect(!hasGlobChars("init"));
    try std.testing.expect(!hasGlobChars(""));
    try std.testing.expect(!hasGlobChars("foo.bar"));
}

test "splitAlternatives" {
    // Single name, no pipe
    const single = splitAlternatives("banner");
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings("banner", single.items()[0]);

    // Two alternatives
    const two = splitAlternatives("banner|header");
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("banner", two.items()[0]);
    try std.testing.expectEqualStrings("header", two.items()[1]);

    // Three alternatives
    const three = splitAlternatives("banner|header|splash");
    try std.testing.expectEqual(@as(usize, 3), three.len);
    try std.testing.expectEqualStrings("banner", three.items()[0]);
    try std.testing.expectEqualStrings("header", three.items()[1]);
    try std.testing.expectEqualStrings("splash", three.items()[2]);

    // Glob patterns mixed with plain names
    const mixed = splitAlternatives("*init*|setup|*boot*");
    try std.testing.expectEqual(@as(usize, 3), mixed.len);
    try std.testing.expectEqualStrings("*init*", mixed.items()[0]);
    try std.testing.expectEqualStrings("setup", mixed.items()[1]);
    try std.testing.expectEqualStrings("*boot*", mixed.items()[2]);

    // Empty segments are skipped
    const with_empty = splitAlternatives("foo||bar");
    try std.testing.expectEqual(@as(usize, 2), with_empty.len);
    try std.testing.expectEqualStrings("foo", with_empty.items()[0]);
    try std.testing.expectEqualStrings("bar", with_empty.items()[1]);

    // Trailing pipe
    const trailing = splitAlternatives("foo|");
    try std.testing.expectEqual(@as(usize, 1), trailing.len);
    try std.testing.expectEqualStrings("foo", trailing.items()[0]);
}

test "fileMatchesSuffix" {
    // Exact match
    try std.testing.expect(fileMatchesSuffix("src/main.zig", "src/main.zig"));

    // Suffix match: indexed path ends with filter
    try std.testing.expect(fileMatchesSuffix("src/main.zig", "main.zig"));

    // Prefix match: filter ends with indexed path
    try std.testing.expect(fileMatchesSuffix("main.zig", "/Users/foo/project/main.zig"));

    // No match
    try std.testing.expect(!fileMatchesSuffix("src/main.zig", "other.zig"));
    try std.testing.expect(!fileMatchesSuffix("src/main.zig", "src/other.zig"));
}

test "findSymbol with glob patterns" {
    const allocator = std.testing.allocator;

    var occurrences = try allocator.alloc(scip.Occurrence, 2);
    defer allocator.free(occurrences);
    occurrences[0] = .{
        .range = .{ .start_line = 10, .start_char = 0, .end_line = 10, .end_char = 5 },
        .symbol = "pkg/Foo#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occurrences[1] = .{
        .range = .{ .start_line = 15, .start_char = 4, .end_line = 15, .end_char = 10 },
        .symbol = "pkg/Foo#bar().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    var doc_symbols = try allocator.alloc(scip.SymbolInformation, 2);
    defer allocator.free(doc_symbols);
    doc_symbols[0] = .{
        .symbol = "pkg/Foo#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49,
        .display_name = "Foo",
        .enclosing_symbol = "",
    };
    doc_symbols[1] = .{
        .symbol = "pkg/Foo#bar().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 26,
        .display_name = "bar",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 1);
    documents[0] = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = occurrences,
        .symbols = doc_symbols,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    var ci = try CodeIndex.build(allocator, index);
    defer {
        ci.symbol_to_defs.deinit(allocator);
        var ref_iter = ci.symbol_to_refs.iterator();
        while (ref_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        ci.symbol_to_refs.deinit(allocator);
        ci.path_to_doc_idx.deinit(allocator);
        allocator.free(ci.index.documents);
    }

    // Glob pattern matching
    var glob_matches = try ci.findSymbol(allocator, "*oo*", null, null);
    defer glob_matches.deinit(allocator);
    try std.testing.expect(glob_matches.items.len > 0);
    // Should find "Foo" (display_name contains "oo")
    try std.testing.expectEqualStrings("pkg/Foo#", glob_matches.items[0].symbol);

    // Glob pattern with star prefix
    var bar_matches = try ci.findSymbol(allocator, "*ar", null, null);
    defer bar_matches.deinit(allocator);
    try std.testing.expect(bar_matches.items.len > 0);
    try std.testing.expectEqualStrings("pkg/Foo#bar().", bar_matches.items[0].symbol);

    // File filter matching
    var file_matches = try ci.findSymbol(allocator, "Foo", null, "foo.go");
    defer file_matches.deinit(allocator);
    try std.testing.expect(file_matches.items.len > 0);

    // File filter non-matching
    var no_file_matches = try ci.findSymbol(allocator, "Foo", null, "other.go");
    defer no_file_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_file_matches.items.len);
}

test "findSymbol with alternation" {
    const allocator = std.testing.allocator;

    var occurrences = try allocator.alloc(scip.Occurrence, 3);
    defer allocator.free(occurrences);
    occurrences[0] = .{
        .range = .{ .start_line = 1, .start_char = 0, .end_line = 1, .end_char = 6 },
        .symbol = "pkg/Header#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occurrences[1] = .{
        .range = .{ .start_line = 10, .start_char = 0, .end_line = 10, .end_char = 6 },
        .symbol = "pkg/Splash#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occurrences[2] = .{
        .range = .{ .start_line = 20, .start_char = 0, .end_line = 20, .end_char = 6 },
        .symbol = "pkg/Footer#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    var doc_symbols = try allocator.alloc(scip.SymbolInformation, 3);
    defer allocator.free(doc_symbols);
    doc_symbols[0] = .{
        .symbol = "pkg/Header#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49,
        .display_name = "Header",
        .enclosing_symbol = "",
    };
    doc_symbols[1] = .{
        .symbol = "pkg/Splash#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49,
        .display_name = "Splash",
        .enclosing_symbol = "",
    };
    doc_symbols[2] = .{
        .symbol = "pkg/Footer#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49,
        .display_name = "Footer",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 1);
    documents[0] = .{
        .language = "go",
        .relative_path = "pkg/ui.go",
        .occurrences = occurrences,
        .symbols = doc_symbols,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    var ci = try CodeIndex.build(allocator, index);
    defer {
        ci.symbol_to_defs.deinit(allocator);
        var ref_iter = ci.symbol_to_refs.iterator();
        while (ref_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        ci.symbol_to_refs.deinit(allocator);
        ci.path_to_doc_idx.deinit(allocator);
        allocator.free(ci.index.documents);
    }

    // Alternation: "Banner|Header" should find Header (no Banner exists)
    var alt_matches = try ci.findSymbol(allocator, "Banner|Header", null, null);
    defer alt_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), alt_matches.items.len);
    try std.testing.expectEqualStrings("pkg/Header#", alt_matches.items[0].symbol);

    // Alternation: "Header|Splash" should find both
    var both_matches = try ci.findSymbol(allocator, "Header|Splash", null, null);
    defer both_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), both_matches.items.len);

    // Alternation with globs: "*ead*|*oot*" should find Header and Footer
    var glob_alt = try ci.findSymbol(allocator, "*ead*|*oot*", null, null);
    defer glob_alt.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), glob_alt.items.len);

    // No match at all
    var no_matches = try ci.findSymbol(allocator, "Banner|Logo|Title", null, null);
    defer no_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_matches.items.len);
}

test "CodeIndex build resolves later cross-document calls and uses smallest enclosing definition" {
    const allocator = std.testing.allocator;

    var caller_occurrences = try allocator.alloc(scip.Occurrence, 3);
    caller_occurrences[0] = .{
        .range = .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 5 },
        .symbol = "local src/caller.js:0",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 0, .start_char = 0, .end_line = 8, .end_char = 1 },
    };
    caller_occurrences[1] = .{
        .range = .{ .start_line = 2, .start_char = 4, .end_line = 2, .end_char = 9 },
        .symbol = "local src/caller.js:1",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 2, .start_char = 4, .end_line = 5, .end_char = 5 },
    };
    caller_occurrences[2] = .{
        .range = .{ .start_line = 4, .start_char = 8, .end_line = 4, .end_char = 14 },
        .symbol = "cog/call/helper",
        .symbol_roles = scip.SymbolRole.ReadAccess,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 2, .start_char = 4, .end_line = 5, .end_char = 5 },
    };

    var caller_symbols = try allocator.alloc(scip.SymbolInformation, 2);
    caller_symbols[0] = .{
        .symbol = "local src/caller.js:0",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 17,
        .display_name = "outer",
        .enclosing_symbol = "",
    };
    caller_symbols[1] = .{
        .symbol = "local src/caller.js:1",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 17,
        .display_name = "inner",
        .enclosing_symbol = "local src/caller.js:0",
    };

    var callee_occurrences = try allocator.alloc(scip.Occurrence, 1);
    callee_occurrences[0] = .{
        .range = .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 6 },
        .symbol = "local src/helper.js:0",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 0, .start_char = 0, .end_line = 1, .end_char = 1 },
    };

    var callee_symbols = try allocator.alloc(scip.SymbolInformation, 1);
    callee_symbols[0] = .{
        .symbol = "local src/helper.js:0",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 17,
        .display_name = "helper",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 2);
    documents[0] = .{
        .language = "javascript",
        .relative_path = "src/caller.js",
        .occurrences = caller_occurrences,
        .symbols = caller_symbols,
    };
    documents[1] = .{
        .language = "javascript",
        .relative_path = "src/helper.js",
        .occurrences = callee_occurrences,
        .symbols = callee_symbols,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    var ci = try CodeIndex.build(allocator, index);
    defer deinitTestIndex(&ci, allocator);

    const calls = ci.getCalls("local src/caller.js:1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), calls.items.len);
    try std.testing.expectEqualStrings("local src/helper.js:0", calls.items[0].symbol);
    try std.testing.expect(ci.getCalls("local src/caller.js:0") == null);

    const callers = ci.getCallers("local src/helper.js:0") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), callers.items.len);
    try std.testing.expectEqualStrings("local src/caller.js:1", callers.items[0].symbol);
}

test "CodeIndex build canonicalizes later cross-document imports" {
    const allocator = std.testing.allocator;

    var importer_occurrences = try allocator.alloc(scip.Occurrence, 1);
    importer_occurrences[0] = .{
        .range = .{ .start_line = 0, .start_char = 20, .end_line = 0, .end_char = 28 },
        .symbol = "cog/import/src/helper",
        .symbol_roles = scip.SymbolRole.Import,
        .syntax_kind = 0,
    };

    var importer_symbols = try allocator.alloc(scip.SymbolInformation, 1);
    importer_symbols[0] = .{
        .symbol = "local src/main.ts:0",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 17,
        .display_name = "main",
        .enclosing_symbol = "",
    };

    var target_occurrences = try allocator.alloc(scip.Occurrence, 1);
    target_occurrences[0] = .{
        .range = .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 6 },
        .symbol = "local src/helper.ts:0",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 20 },
    };

    var target_symbols = try allocator.alloc(scip.SymbolInformation, 1);
    target_symbols[0] = .{
        .symbol = "local src/helper.ts:0",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 17,
        .display_name = "helper",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 2);
    documents[0] = .{
        .language = "typescript",
        .relative_path = "src/main.ts",
        .occurrences = importer_occurrences,
        .symbols = importer_symbols,
    };
    documents[1] = .{
        .language = "typescript",
        .relative_path = "src/helper.ts",
        .occurrences = target_occurrences,
        .symbols = target_symbols,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    var ci = try CodeIndex.build(allocator, index);
    defer deinitTestIndex(&ci, allocator);

    const imports = ci.getFileImports("src/main.ts") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try std.testing.expectEqualStrings("src/helper.ts", imports.items[0].label);

    const output = try queryImportsInner(allocator, &ci, null, "src/helper.ts", .incoming);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "src/main.ts") != null);
}

// ── Disambiguation Tests ────────────────────────────────────────────────

/// Helper to build a synthetic CodeIndex for disambiguation tests.
/// File A (src/commands.zig): defines init (function), initBrain (function), references Settings symbol
/// File B (src/settings.zig): defines Settings (struct), load (function)
/// File C (src/http.zig): defines init (function) — unrelated init
fn buildTestDisambiguationIndex(allocator: std.mem.Allocator) !CodeIndex {
    // File A: src/commands.zig — defines init, initBrain, references Settings
    var occ_a = try allocator.alloc(scip.Occurrence, 5);
    occ_a[0] = .{
        .range = .{ .start_line = 5, .start_char = 0, .end_line = 5, .end_char = 4 },
        .symbol = "proj/commands.zig/init().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 5, .start_char = 0, .end_line = 12, .end_char = 1 },
    };
    occ_a[1] = .{
        .range = .{ .start_line = 20, .start_char = 0, .end_line = 20, .end_char = 9 },
        .symbol = "proj/commands.zig/initBrain().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 20, .start_char = 0, .end_line = 22, .end_char = 1 },
    };
    occ_a[2] = .{
        .range = .{ .start_line = 10, .start_char = 4, .end_line = 10, .end_char = 12 },
        .symbol = "proj/settings.zig/Settings#",
        .symbol_roles = 0, // reference, not definition
        .syntax_kind = 0,
    };
    occ_a[3] = .{
        .range = .{ .start_line = 1, .start_char = 18, .end_line = 1, .end_char = 30 },
        .symbol = "cog/import/src/settings.zig",
        .symbol_roles = scip.SymbolRole.Import,
        .syntax_kind = 0,
    };
    occ_a[4] = .{
        .range = .{ .start_line = 21, .start_char = 4, .end_line = 21, .end_char = 8 },
        .symbol = "cog/call/init",
        .symbol_roles = scip.SymbolRole.ReadAccess,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 20, .start_char = 0, .end_line = 22, .end_char = 1 },
    };

    var sym_a = try allocator.alloc(scip.SymbolInformation, 2);
    var init_relationships = try allocator.alloc(scip.Relationship, 1);
    init_relationships[0] = .{
        .symbol = "cog/import/src/settings.zig",
        .is_reference = false,
        .is_implementation = false,
        .is_type_definition = false,
        .is_definition = false,
        .kind = "imports",
    };
    sym_a[0] = .{
        .symbol = "proj/commands.zig/init().",
        .documentation = &.{},
        .relationships = init_relationships,
        .kind = 12, // function
        .display_name = "init",
        .enclosing_symbol = "",
    };
    sym_a[1] = .{
        .symbol = "proj/commands.zig/initBrain().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "initBrain",
        .enclosing_symbol = "",
    };

    // File B: src/settings.zig — defines Settings, load
    var occ_b = try allocator.alloc(scip.Occurrence, 2);
    occ_b[0] = .{
        .range = .{ .start_line = 3, .start_char = 0, .end_line = 3, .end_char = 8 },
        .symbol = "proj/settings.zig/Settings#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 3, .start_char = 0, .end_line = 31, .end_char = 1 },
    };
    occ_b[1] = .{
        .range = .{ .start_line = 30, .start_char = 0, .end_line = 30, .end_char = 4 },
        .symbol = "proj/settings.zig/load().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 30, .start_char = 0, .end_line = 31, .end_char = 1 },
    };

    var sym_b = try allocator.alloc(scip.SymbolInformation, 2);
    sym_b[0] = .{
        .symbol = "proj/settings.zig/Settings#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49, // struct
        .display_name = "Settings",
        .enclosing_symbol = "",
    };
    sym_b[1] = .{
        .symbol = "proj/settings.zig/load().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "load",
        .enclosing_symbol = "proj/settings.zig/Settings#",
    };

    // File C: src/http.zig — defines init (unrelated)
    var occ_c = try allocator.alloc(scip.Occurrence, 1);
    occ_c[0] = .{
        .range = .{ .start_line = 8, .start_char = 0, .end_line = 8, .end_char = 4 },
        .symbol = "proj/http.zig/init().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
        .enclosing_range = .{ .start_line = 8, .start_char = 0, .end_line = 10, .end_char = 1 },
    };

    var sym_c = try allocator.alloc(scip.SymbolInformation, 1);
    sym_c[0] = .{
        .symbol = "proj/http.zig/init().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "init",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 3);
    documents[0] = .{
        .language = "zig",
        .relative_path = "src/commands.zig",
        .occurrences = occ_a,
        .symbols = sym_a,
    };
    documents[1] = .{
        .language = "zig",
        .relative_path = "src/settings.zig",
        .occurrences = occ_b,
        .symbols = sym_b,
    };
    documents[2] = .{
        .language = "zig",
        .relative_path = "src/http.zig",
        .occurrences = occ_c,
        .symbols = sym_c,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    return try CodeIndex.build(allocator, index);
}

fn deinitTestIndex(ci: *CodeIndex, allocator: std.mem.Allocator) void {
    // Free occurrence and symbol arrays for each document
    for (ci.index.documents) |doc| {
        allocator.free(doc.occurrences);
        for (doc.symbols) |sym| {
            allocator.free(sym.relationships);
        }
        allocator.free(doc.symbols);
    }
    ci.symbol_to_defs.deinit(allocator);
    var ref_iter = ci.symbol_to_refs.iterator();
    while (ref_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.symbol_to_refs.deinit(allocator);
    ci.path_to_doc_idx.deinit(allocator);
    ci.symbol_to_parent.deinit(allocator);
    var child_iter = ci.parent_to_children.iterator();
    while (child_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.parent_to_children.deinit(allocator);
    var rel_iter = ci.symbol_to_relationships.iterator();
    while (rel_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.symbol_to_relationships.deinit(allocator);
    var rev_iter = ci.symbol_to_reverse_relationships.iterator();
    while (rev_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.symbol_to_reverse_relationships.deinit(allocator);
    var import_iter = ci.file_to_imports.iterator();
    while (import_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.file_to_imports.deinit(allocator);
    var call_iter = ci.symbol_to_calls.iterator();
    while (call_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.symbol_to_calls.deinit(allocator);
    var caller_iter = ci.symbol_to_callers.iterator();
    while (caller_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.symbol_to_callers.deinit(allocator);
    allocator.free(ci.index.documents);
}

test "disambiguateBatch: anchor resolves floater" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [init, Settings]
    // Settings has 1 match (anchor), init has 2 matches (floater)
    var matches_init = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init.deinit(allocator);
    var matches_settings = try ci.findSymbol(allocator, "Settings", null, null);
    defer matches_settings.deinit(allocator);

    // Verify init is ambiguous and Settings is anchor
    try std.testing.expect(matches_init.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), matches_settings.items.len);

    var all_matches = [_]CodeIndex.MatchList{ matches_init, matches_settings };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Settings (index 1) should select 0 (only match)
    try std.testing.expectEqual(@as(?usize, 0), selected[1]);

    // init (index 0) should pick the one from commands.zig because it
    // co-occurs with Settings (Settings is referenced in commands.zig)
    const init_idx = selected[0] orelse 0;
    const chosen_init = matches_init.items[init_idx];
    try std.testing.expectEqualStrings("src/commands.zig", chosen_init.def.path);
}

test "disambiguateBatch: all anchors" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [Settings, initBrain] — both unique
    var matches_settings = try ci.findSymbol(allocator, "Settings", null, null);
    defer matches_settings.deinit(allocator);
    var matches_initbrain = try ci.findSymbol(allocator, "initBrain", null, null);
    defer matches_initbrain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), matches_settings.items.len);
    try std.testing.expectEqual(@as(usize, 1), matches_initbrain.items.len);

    var all_matches = [_]CodeIndex.MatchList{ matches_settings, matches_initbrain };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    try std.testing.expectEqual(@as(?usize, 0), selected[0]);
    try std.testing.expectEqual(@as(?usize, 0), selected[1]);
}

test "disambiguateBatch: all floaters pair-linking" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [init, load] — both ambiguous (init has 2 matches)
    // load has 1 match, but let's verify the pair-linking path works.
    // Since load only has 1 match it's actually an anchor. Let's construct
    // a scenario with truly all-floater queries by using init twice with kind filter off.
    var matches_init = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init.deinit(allocator);

    // Skip if init has fewer than 2 matches
    if (matches_init.items.len < 2) return;

    // Create a second copy of init matches to simulate two floaters
    var matches_init2 = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init2.deinit(allocator);

    var all_matches = [_]CodeIndex.MatchList{ matches_init, matches_init2 };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Both should get a selection (not null)
    try std.testing.expect(selected[0] != null);
    try std.testing.expect(selected[1] != null);
}

test "disambiguateBatch: empty query" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [nonexistent, Settings]
    var matches_none = try ci.findSymbol(allocator, "nonexistent_symbol_xyz", null, null);
    defer matches_none.deinit(allocator);
    var matches_settings = try ci.findSymbol(allocator, "Settings", null, null);
    defer matches_settings.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), matches_none.items.len);

    var all_matches = [_]CodeIndex.MatchList{ matches_none, matches_settings };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Empty query should have null selection
    try std.testing.expectEqual(@as(?usize, null), selected[0]);
    // Settings should select 0
    try std.testing.expectEqual(@as(?usize, 0), selected[1]);
}

test "disambiguateBatch: empty query with floater" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [nonexistent, init] — empty + floater combo
    // This exercises the path where the null-to-0 fallback would have
    // incorrectly overwritten the empty query's null selection.
    var matches_none = try ci.findSymbol(allocator, "nonexistent_symbol_xyz", null, null);
    defer matches_none.deinit(allocator);
    var matches_init = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), matches_none.items.len);
    try std.testing.expect(matches_init.items.len >= 2);

    var all_matches = [_]CodeIndex.MatchList{ matches_none, matches_init };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Empty query must remain null even with floaters present
    try std.testing.expectEqual(@as(?usize, null), selected[0]);
    // init should get a selection
    try std.testing.expect(selected[1] != null);
}

test "sameDirectory" {
    try std.testing.expect(sameDirectory("src/foo.zig", "src/bar.zig"));
    try std.testing.expect(!sameDirectory("src/foo.zig", "lib/bar.zig"));
    try std.testing.expect(sameDirectory("foo.zig", "bar.zig")); // both root
}

test "buildFileOccurrenceSet" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // commands.zig should have occurrences for init, initBrain, and Settings reference
    var set = ci.buildFileOccurrenceSet(allocator, "src/commands.zig");
    defer set.deinit(allocator);

    try std.testing.expect(set.contains("proj/commands.zig/init()."));
    try std.testing.expect(set.contains("proj/commands.zig/initBrain()."));
    try std.testing.expect(set.contains("proj/settings.zig/Settings#"));

    // Non-existent file returns empty set
    var empty_set = ci.buildFileOccurrenceSet(allocator, "nonexistent.zig");
    defer empty_set.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), empty_set.count());
}

test "isSymbolInFile" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Settings symbol is referenced in commands.zig
    try std.testing.expect(ci.isSymbolInFile("src/commands.zig", "proj/settings.zig/Settings#"));
    // Settings symbol is NOT referenced in http.zig
    try std.testing.expect(!ci.isSymbolInFile("src/http.zig", "proj/settings.zig/Settings#"));
    // Non-existent file
    try std.testing.expect(!ci.isSymbolInFile("nonexistent.zig", "proj/settings.zig/Settings#"));
}

// ── readDefinitionBody tests ─────────────────────────────────────────────

fn testReadBodyFromContent(allocator: std.mem.Allocator, content: []const u8, def_line: i32, def_end_line: i32, fallback_context: usize) !ReadBodyResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "body.zig", .data = content });

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    return readDefinitionBody(allocator, root, "body.zig", def_line, def_end_line, fallback_context);
}

fn withTempCwd(comptime body: fn (std.mem.Allocator) anyerror!void) !void {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    tmp_dir.dir.setAsCwd() catch unreachable;
    try body(allocator);
}

test "queryIndexStatusForRuntime returns unavailable without index" {
    const allocator = std.testing.allocator;
    var original_cwd = std.fs.cwd().openDir(".", .{}) catch unreachable;
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }

    var root_dir = try std.fs.openDirAbsolute("/", .{});
    defer root_dir.close();
    try root_dir.setAsCwd();

    try std.testing.expect(queryIndexStatusForRuntime(allocator) == .unavailable);
}

test "queryIndexStatusForRuntime returns unavailable for invalid index" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            std.fs.cwd().makeDir(".cog") catch {};
            const file = try std.fs.cwd().createFile(".cog/index.scip", .{});
            defer file.close();
            try file.writeAll("not-a-valid-scip-index");

            try std.testing.expect(queryIndexStatusForRuntime(allocator) == .unavailable);
        }
    }.run);
}

test "parseIndexerProgressEvent parses file_done event" {
    const allocator = std.testing.allocator;
    const line = "{\"type\":\"progress\",\"event\":\"file_done\",\"path\":\"lib/foo.ex\"}";
    const event = try parseIndexerProgressEvent(allocator, line);
    switch (event) {
        .file_done => |path| {
            defer allocator.free(path);
            try std.testing.expectEqualStrings("lib/foo.ex", path);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseIndexerProgressEvent ignores non-json" {
    const allocator = std.testing.allocator;
    const event = try parseIndexerProgressEvent(allocator, "warning: hello");
    try std.testing.expect(event == .ignore);
}

test "parseIndexerProgressEvent parses phase event" {
    const allocator = std.testing.allocator;
    const line = "{\"type\":\"progress\",\"event\":\"phase\",\"phase\":\"analyze\",\"done\":1,\"total\":4,\"path\":\"src/main.zig\"}";
    const event = try parseIndexerProgressEvent(allocator, line);
    switch (event) {
        .phase => |phase| {
            defer allocator.free(phase.phase);
            defer allocator.free(phase.path.?);
            try std.testing.expectEqualStrings("analyze", phase.phase);
            try std.testing.expectEqualStrings("src/main.zig", phase.path.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "mergeExternalSymbolList replaces duplicates by symbol" {
    const allocator = std.testing.allocator;

    var list: std.ArrayListUnmanaged(scip.SymbolInformation) = .empty;
    defer {
        for (list.items) |*sym| freeSymbolInformation(allocator, sym);
        list.deinit(allocator);
    }

    try list.append(allocator, .{
        .symbol = "ext/Foo#",
        .documentation = try allocator.dupe([]const u8, &.{"old"}),
        .relationships = try allocator.alloc(scip.Relationship, 0),
        .kind = 7,
        .display_name = "Foo",
        .enclosing_symbol = "",
    });

    mergeExternalSymbolList(allocator, &list, .{
        .symbol = "ext/Foo#",
        .documentation = try allocator.dupe([]const u8, &.{"new"}),
        .relationships = try allocator.alloc(scip.Relationship, 0),
        .kind = 17,
        .display_name = "Foo",
        .enclosing_symbol = "",
    });

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(i32, 17), list.items[0].kind);
    try std.testing.expectEqualStrings("new", list.items[0].documentation[0]);
}

test "readDefinitionBody: function with enclosing_range" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\pub fn hello(name: []const u8) void {
        \\    std.debug.print("hello {s}\n", .{name});
        \\}
        \\
        \\pub fn other() void {}
    ;
    // def_line=2, def_end_line=4 (enclosing_range covers lines 2-4)
    const result = try testReadBodyFromContent(allocator, content, 2, 4, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "std.debug.print") != null);
    // Should NOT contain the other function
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn other") == null);
}

test "readDefinitionBody: struct with enclosing_range" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\pub const MyStruct = struct {
        \\    field_a: u32,
        \\    field_b: struct {
        \\        inner: bool,
        \\    },
        \\
        \\    pub fn method(self: *MyStruct) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\const other = 42;
    ;
    // def_line=2, def_end_line=11 (struct body ends at };)
    const result = try testReadBodyFromContent(allocator, content, 2, 11, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub const MyStruct") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn method") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "};") != null);
    // Should NOT contain "const other"
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "const other") == null);
}

test "readDefinitionBody: fallback without enclosing_range" {
    const allocator = std.testing.allocator;
    const content =
        \\const a = 1;
        \\const b = 2;
        \\const target = 42;
        \\const d = 4;
        \\const e = 5;
    ;
    // def_end_line=0 means no enclosing_range — uses fallback_context window
    const result = try testReadBodyFromContent(allocator, content, 2, 0, 2);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "const target = 42;") != null);
}

test "readDefinitionBody: doc comments captured" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\/// This is a doc comment
        \\/// for the hello function
        \\pub fn hello() void {
        \\    return;
        \\}
    ;
    // def_line=4, def_end_line=6 (function body)
    const result = try testReadBodyFromContent(allocator, content, 4, 6, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "/// This is a doc comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "/// for the hello function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn hello") != null);
}

test "readDefinitionBody: truncation at MAX_BODY_LINES" {
    const allocator = std.testing.allocator;
    // Create content with more than MAX_BODY_LINES
    var content_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer content_buf.deinit(allocator);
    try content_buf.appendSlice(allocator, "pub fn big() void {\n");
    for (0..200) |i| {
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "    _ = {};\n", .{i}) catch unreachable;
        try content_buf.appendSlice(allocator, line);
    }
    try content_buf.appendSlice(allocator, "}\n");

    // def_end_line=201 (past MAX_BODY_LINES)
    const result = try testReadBodyFromContent(allocator, content_buf.items, 0, 201, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(result.truncated);
}

test "queryFindInner returns readable text" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryFindInner(allocator, &ci, "init", null, null);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Matches for `init`:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "- `init` (enum_member) `src/commands.zig:5-12`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "- `init` (enum_member) `src/http.zig:8-10`") != null);
}

test "queryRefsInner returns readable text" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryRefsInner(allocator, &ci, "Settings", null, null);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "References for `Settings` (struct)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Definition: `src/settings.zig:3`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Total: 2") != null);
}

test "querySymbolsInner returns readable text" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try querySymbolsInner(allocator, &ci, "src/commands.zig", null);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Symbols in `src/commands.zig`:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`init` (enum_member) `5`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`initBrain` (enum_member) `20`") != null);
}

test "codeExploreWithLoadedIndex returns readable text" {
    try withTempCwd(struct {
        fn run(allocator: std.mem.Allocator) !void {
            var ci = try buildTestDisambiguationIndex(allocator);
            defer deinitTestIndex(&ci, allocator);

            try std.fs.cwd().makePath(".cog");
            try std.fs.cwd().makePath("src");

            {
                const file = try std.fs.cwd().createFile("src/commands.zig", .{});
                defer file.close();
                try file.writeAll(
                    \\const Settings = @import("settings.zig").Settings;
                    \\
                    \\pub fn bootstrap() void {}
                    \\
                    \\pub fn init() void {
                    \\    const settings = Settings{};
                    \\    _ = settings;
                    \\}
                    \\
                    \\pub fn initBrain() void {
                    \\    init();
                    \\}
                );
            }

            {
                const file = try std.fs.cwd().createFile("src/settings.zig", .{});
                defer file.close();
                try file.writeAll(
                    \\pub const Settings = struct {};
                    \\
                    \\pub fn load() Settings {
                    \\    return .{};
                    \\}
                );
            }

            const result = try codeExploreWithLoadedIndex(allocator, &ci, &.{
                .{ .name = "init" },
                .{ .name = "Settings", .kind = "struct" },
            }, .{ .context_lines = 5, .include_architecture = true });
            defer allocator.free(result);

            try std.testing.expect(std.mem.indexOf(u8, result, "`init` (enum_member)") != null);
            try std.testing.expect(std.mem.indexOf(u8, result, "`src/commands.zig:5-12`") != null);
            try std.testing.expect(std.mem.indexOf(u8, result, "Snippet:") != null);
            try std.testing.expect(std.mem.indexOf(u8, result, "Nearby:") != null);
            try std.testing.expect(std.mem.indexOf(u8, result, "Architecture:") != null);
        }
    }.run);
}

test "queryImportsInner returns architecture text" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryImportsInner(allocator, &ci, null, "src/commands.zig", .both);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Imports for `src/commands.zig`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/settings.zig") != null);
}

test "queryContainsInner returns parent child relationships" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryContainsInner(allocator, &ci, "Settings", null, .both);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Parent:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Children:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "load") != null);
}

test "queryCallsInner returns outgoing call graph" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryCallsInner(allocator, &ci, "initBrain");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Calls from `initBrain`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "init") != null);
}

test "queryCallersInner returns incoming call graph" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryCallersInner(allocator, &ci, "init");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Callers of `init`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "initBrain") != null);
}

test "queryOverviewInner repo reports entrypoints and imports" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    const result = try queryOverviewInner(allocator, &ci, null, null, .repo);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Repository overview") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/commands.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Subsystems:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "score") != null);
}

// ── discoverRelatedSymbols tests ─────────────────────────────────────────

test "discoverRelatedSymbols: discovers co-file symbols" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query "init" in commands.zig — should discover initBrain and Settings as related
    var queried_files = std.ArrayListUnmanaged([]const u8){};
    defer queried_files.deinit(allocator);
    try queried_files.append(allocator, "src/commands.zig");

    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);
    try queried_symbols.put(allocator, "proj/commands.zig/init().", {});

    var related = try discoverRelatedSymbols(allocator, &ci, queried_files.items, &queried_symbols, MAX_RELATED);
    defer related.deinit(allocator);

    // Should find at least initBrain (defined in commands.zig) and Settings (referenced)
    try std.testing.expect(related.items.len >= 1);

    // initBrain should be in the results (defined in same file)
    var found_init_brain = false;
    for (related.items) |rel| {
        if (std.mem.eql(u8, rel.symbol, "proj/commands.zig/initBrain().")) {
            found_init_brain = true;
        }
    }
    try std.testing.expect(found_init_brain);
}

test "discoverRelatedSymbols: excludes already-queried symbols" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    var queried_files = std.ArrayListUnmanaged([]const u8){};
    defer queried_files.deinit(allocator);
    try queried_files.append(allocator, "src/commands.zig");

    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);
    // Mark both init AND initBrain as queried
    try queried_symbols.put(allocator, "proj/commands.zig/init().", {});
    try queried_symbols.put(allocator, "proj/commands.zig/initBrain().", {});

    var related = try discoverRelatedSymbols(allocator, &ci, queried_files.items, &queried_symbols, MAX_RELATED);
    defer related.deinit(allocator);

    // initBrain should NOT be in results since it was queried
    for (related.items) |rel| {
        try std.testing.expect(!std.mem.eql(u8, rel.symbol, "proj/commands.zig/initBrain()."));
    }
}

test "discoverRelatedSymbols: respects max_related cap" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    var queried_files = std.ArrayListUnmanaged([]const u8){};
    defer queried_files.deinit(allocator);
    try queried_files.append(allocator, "src/commands.zig");
    try queried_files.append(allocator, "src/settings.zig");
    try queried_files.append(allocator, "src/http.zig");

    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);

    // Cap at 1
    var related = try discoverRelatedSymbols(allocator, &ci, queried_files.items, &queried_symbols, 1);
    defer related.deinit(allocator);

    try std.testing.expect(related.items.len <= 1);
}

// ── findReferencesInRange tests ──────────────────────────────────────────

test "findReferencesInRange: finds symbols referenced within range" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // In commands.zig, init is defined at line 5, Settings is referenced at line 10, initBrain at line 20
    // Range 5-15 should find Settings but not initBrain
    var refs = ci.findReferencesInRange(allocator, "src/commands.zig", "proj/commands.zig/init().", 5, 15);
    defer refs.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqualStrings("Settings", refs.items[0]);
}

test "findReferencesInRange: excludes self symbol" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Range 0-25 covers init (line 5), Settings ref (line 10), initBrain (line 20)
    // Should find Settings and initBrain but NOT init itself
    var refs = ci.findReferencesInRange(allocator, "src/commands.zig", "proj/commands.zig/init().", 0, 25);
    defer refs.deinit(allocator);

    for (refs.items) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "init"));
    }
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "findReferencesInRange: returns empty for unknown file" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    var refs = ci.findReferencesInRange(allocator, "src/nonexistent.zig", "proj/foo/bar().", 0, 100);
    defer refs.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

// ── Auto-retry tests ─────────────────────────────────────────────────────

test "auto-retry: glob retry finds partial match" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // "Brain" doesn't match exactly, but "*Brain*" should find initBrain
    var no_match = try ci.findSymbol(allocator, "Brain", null, null);
    defer no_match.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_match.items.len);

    var glob_match = try ci.findSymbol(allocator, "*Brain*", null, null);
    defer glob_match.deinit(allocator);
    try std.testing.expect(glob_match.items.len > 0);

    // Verify the found symbol is initBrain
    try std.testing.expect(std.mem.eql(u8, glob_match.items[0].def.display_name, "initBrain"));
}

test "external indexer uses private project output and cleans it up" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.setAsCwd();

    var fixture_documents = [_]scip.Document{.{
        .language = "zig",
        .relative_path = "src/main.zig",
        .occurrences = &.{},
        .symbols = &.{},
    }};
    const fixture_index = scip.Index{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "fixture", .version = "1.0" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &fixture_documents,
        .external_symbols = &.{},
    };
    const encoded = try scip_encode.encodeIndex(allocator, fixture_index);
    defer allocator.free(encoded);
    const hex = try std.fmt.allocPrint(allocator, "{x}", .{encoded});
    defer allocator.free(hex);
    const script = try std.fmt.allocPrint(
        allocator,
        "case \"$1\" in \"$PWD/.cog/tmp/\"*) ;; *) exit 41 ;; esac; perm=$(stat -c %a \"$1\" 2>/dev/null) || perm=$(stat -f %Lp \"$1\") || exit 42; [ \"$perm\" = 600 ] || exit 42; printf '%s' '{s}' | xxd -r -p > \"$1\"",
        .{hex},
    );
    defer allocator.free(script);

    var result = try invokeIndexerWithSubstitutions(
        allocator,
        .{ .command = "/bin/sh", .args = &.{ "-c", script, "cog-test-indexer", "{output}" } },
        &.{},
        null,
        null,
    );
    defer {
        scip.freeIndex(allocator, &result.index);
        if (result.backing_data) |data| allocator.free(data);
    }
    try std.testing.expectEqual(@as(usize, 1), result.index.documents.len);

    var temp_dir = try std.fs.cwd().openDir(".cog/tmp", .{ .iterate = true });
    defer temp_dir.close();
    var entries = temp_dir.iterate();
    try std.testing.expect((try entries.next()) == null);
}

test "external indexer cleans private output after failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer {
        original_cwd.setAsCwd() catch unreachable;
        original_cwd.close();
    }
    try tmp.dir.makeDir(".cog");
    try tmp.dir.setAsCwd();

    try std.testing.expectError(
        error.IndexerFailed,
        invokeIndexerWithSubstitutions(
            allocator,
            .{ .command = "/bin/sh", .args = &.{ "-c", "printf invalid > \"$1\"; exit 7", "cog-test-indexer", "{output}" } },
            &.{},
            null,
            null,
        ),
    );

    var temp_dir = try std.fs.cwd().openDir(".cog/tmp", .{ .iterate = true });
    defer temp_dir.close();
    var entries = temp_dir.iterate();
    try std.testing.expect((try entries.next()) == null);
}

test "ensureIndexerTermSucceeded accepts zero exit and rejects signal" {
    try ensureIndexerTermSucceeded(.{ .Exited = 0 });
    try std.testing.expectError(error.IndexerFailed, ensureIndexerTermSucceeded(.{ .Exited = 1 }));
    try std.testing.expectError(error.IndexerFailed, ensureIndexerTermSucceeded(.{ .Signal = 9 }));
}
