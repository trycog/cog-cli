const std = @import("std");
const cog = @import("cog");

const code_intel = cog.code_intel;
const debug_log = cog.debug_log;
const scip = cog.scip;

const FIXTURE_ROOT_ENV = "COG_INDEX_BENCH_ROOT";
const SOURCE_FILE_COUNT: usize = 48;
const EXPECTED_SYMBOLS_PER_FILE: usize = 4;
const EXPECTED_DOCUMENTS = SOURCE_FILE_COUNT;
const EXPECTED_SYMBOLS = SOURCE_FILE_COUNT * EXPECTED_SYMBOLS_PER_FILE;
const EXPECTED_OCCURRENCES: usize = 288;
const EXPECTED_INDEX_BYTES: usize = 25_166;
const EXPECTED_QUERY_BYTES: usize = 1_468;
const EXPECTED_INDEX_SHA256 = [_]u8{
    0x2f, 0x33, 0xd1, 0xad, 0xa0, 0x05, 0xde, 0x91,
    0x42, 0x82, 0xf6, 0x60, 0xf4, 0x03, 0x41, 0x4c,
    0x99, 0xbb, 0xa8, 0x56, 0x35, 0x0c, 0x44, 0x83,
    0xbd, 0xb5, 0x73, 0x23, 0x7d, 0xf9, 0xdd, 0x07,
};
const REINDEX_BATCH_SIZE: usize = 8;
const QUERY_COUNT: usize = 4;

const Snapshot = struct {
    encoded_bytes: usize,
    documents: usize,
    symbols: usize,
    occurrences: usize,
    hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

const Measurements = struct {
    full_index_ns: u64,
    reindex_ns: u64,
    load_cache_ns: u64,
    query_ns: u64,
    query_bytes: usize,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn writeSyntheticCorpus(allocator: std.mem.Allocator) !void {
    debug_log.log("bench_indexing: write corpus files={d}", .{SOURCE_FILE_COUNT});
    for (0..SOURCE_FILE_COUNT) |i| {
        const rel_path = try std.fmt.allocPrint(allocator, "pkg_{d:0>2}/module_{d:0>2}.go", .{ i / 8, i });
        defer allocator.free(rel_path);
        if (std.fs.path.dirname(rel_path)) |parent| try std.fs.cwd().makePath(parent);

        const source = try std.fmt.allocPrint(allocator,
            \\package pkg{d:0>2}
            \\
            \\type Type{d:0>2} struct {{
            \\    Value int
            \\}}
            \\
            \\func (item Type{d:0>2}) Compute() int {{
            \\    return helper{d:0>2}(item.Value)
            \\}}
            \\
            \\func helper{d:0>2}(value int) int {{
            \\    return value + {d}
            \\}}
            \\
            \\func entry{d:0>2}() int {{
            \\    item := Type{d:0>2}{{Value: {d}}}
            \\    return item.Compute()
            \\}}
            \\
        , .{ i / 8, i, i, i, i, i + 1, i, i, i + 1 });
        defer allocator.free(source);

        const file = try std.fs.cwd().createFile(rel_path, .{});
        defer file.close();
        try file.writeAll(source);
    }
}

fn snapshotIndex(allocator: std.mem.Allocator, index_path: []const u8) !Snapshot {
    const encoded = try std.fs.cwd().readFileAlloc(allocator, index_path, 64 * 1024 * 1024);
    defer allocator.free(encoded);

    var index = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &index);

    var symbol_count: usize = index.external_symbols.len;
    var occurrence_count: usize = 0;
    for (index.documents) |doc| {
        symbol_count += doc.symbols.len;
        occurrence_count += doc.occurrences.len;
    }

    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
    return .{
        .encoded_bytes = encoded.len,
        .documents = index.documents.len,
        .symbols = symbol_count,
        .occurrences = occurrence_count,
        .hash = hash,
    };
}

fn expectSnapshot(snapshot: Snapshot) void {
    if (snapshot.documents != EXPECTED_DOCUMENTS) {
        fail("indexing benchmark expected {d} documents, found {d}\n", .{ EXPECTED_DOCUMENTS, snapshot.documents });
    }
    if (snapshot.symbols != EXPECTED_SYMBOLS) {
        fail("indexing benchmark expected {d} symbols, found {d}\n", .{ EXPECTED_SYMBOLS, snapshot.symbols });
    }
    if (snapshot.occurrences != EXPECTED_OCCURRENCES) {
        fail("indexing benchmark expected {d} occurrences, found {d}\n", .{ EXPECTED_OCCURRENCES, snapshot.occurrences });
    }
    if (snapshot.encoded_bytes != EXPECTED_INDEX_BYTES) {
        fail("indexing benchmark expected {d} encoded bytes, found {d}\n", .{ EXPECTED_INDEX_BYTES, snapshot.encoded_bytes });
    }
    if (!std.mem.eql(u8, &snapshot.hash, &EXPECTED_INDEX_SHA256)) {
        fail("indexing benchmark index hash changed: {x}\n", .{snapshot.hash});
    }
}

fn runFullIndex(allocator: std.mem.Allocator, index_path: []const u8) !struct { Snapshot, u64 } {
    debug_log.log("bench_indexing: full index start", .{});
    var timer = try std.time.Timer.start();
    const result = try code_intel.codeIndexInner(allocator, &.{"**/*.go"});
    defer allocator.free(result);
    const elapsed = timer.read();
    const snapshot = try snapshotIndex(allocator, index_path);
    expectSnapshot(snapshot);
    debug_log.log("bench_indexing: full index done bytes={d} documents={d} symbols={d}", .{ snapshot.encoded_bytes, snapshot.documents, snapshot.symbols });
    return .{ snapshot, elapsed };
}

fn runReindexBatch(allocator: std.mem.Allocator, index_path: []const u8) !u64 {
    debug_log.log("bench_indexing: reindex batch start files={d}", .{REINDEX_BATCH_SIZE});
    var timer = try std.time.Timer.start();
    for (0..REINDEX_BATCH_SIZE) |i| {
        const rel_path = try std.fmt.allocPrint(allocator, "pkg_{d:0>2}/module_{d:0>2}.go", .{ i / 8, i });
        defer allocator.free(rel_path);
        if (!code_intel.reindexFile(allocator, rel_path)) {
            fail("indexing benchmark failed to reindex {s}\n", .{rel_path});
        }
    }
    const elapsed = timer.read();
    expectSnapshot(try snapshotIndex(allocator, index_path));
    debug_log.log("bench_indexing: reindex batch done", .{});
    return elapsed;
}

fn runLoadAndQueries(allocator: std.mem.Allocator) !struct { u64, u64, usize } {
    debug_log.log("bench_indexing: load/cache start", .{});
    var load_timer = try std.time.Timer.start();
    var ci = try code_intel.loadIndexForRuntime(allocator);
    const load_elapsed = load_timer.read();
    defer ci.deinit(allocator);

    const queries = [_]code_intel.QueryParams{
        .{ .mode = .find, .name = "entry07" },
        .{ .mode = .refs, .name = "Type07" },
        .{ .mode = .symbols, .file = "pkg_00/module_07.go" },
        .{ .mode = .overview, .scope = .repo },
    };
    var query_timer = try std.time.Timer.start();
    const output = try code_intel.codeQueryBatchWithLoadedIndex(allocator, &ci, &queries);
    defer allocator.free(output);
    const query_elapsed = query_timer.read();

    if (std.mem.indexOf(u8, output, "Matches for `entry07`") == null or
        std.mem.indexOf(u8, output, "References for `Type07`") == null or
        std.mem.indexOf(u8, output, "Symbols in `pkg_00/module_07.go`") == null or
        std.mem.indexOf(u8, output, "Repository overview") == null)
    {
        fail("indexing benchmark representative queries returned unexpected output:\n{s}\n", .{output});
    }
    if (output.len != EXPECTED_QUERY_BYTES) {
        fail("indexing benchmark expected {d} query bytes, found {d}\n", .{ EXPECTED_QUERY_BYTES, output.len });
    }

    debug_log.log("bench_indexing: load/cache and queries done query_bytes={d}", .{output.len});
    return .{ load_elapsed, query_elapsed, output.len };
}

fn printReport(snapshot: Snapshot, timings: Measurements) void {
    std.debug.print(
        \\indexing benchmark passed
        \\  corpus: {d} fixed Go files
        \\  index: {d} documents, {d} symbols, {d} occurrences, {d} bytes
        \\  sha256: {x}
        \\  full index: {d:.3} ms
        \\  reindex ({d} files): {d:.3} ms
        \\  load/cache build: {d:.3} ms
        \\  queries ({d}): {d:.3} ms, {d} output bytes
        \\
    , .{
        SOURCE_FILE_COUNT,
        snapshot.documents,
        snapshot.symbols,
        snapshot.occurrences,
        snapshot.encoded_bytes,
        snapshot.hash,
        @as(f64, @floatFromInt(timings.full_index_ns)) / std.time.ns_per_ms,
        REINDEX_BATCH_SIZE,
        @as(f64, @floatFromInt(timings.reindex_ns)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(timings.load_cache_ns)) / std.time.ns_per_ms,
        QUERY_COUNT,
        @as(f64, @floatFromInt(timings.query_ns)) / std.time.ns_per_ms,
        timings.query_bytes,
    });
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer if (gpa.deinit() == .leak) fail("indexing benchmark leaked memory\n", .{});
    const allocator = gpa.allocator();

    const bench_root = std.posix.getenv(FIXTURE_ROOT_ENV) orelse return error.MissingBenchmarkRoot;
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    if (!std.mem.eql(u8, cwd, bench_root)) return error.UnexpectedBenchmarkCwd;
    debug_log.log("bench_indexing: fixture root={s}", .{bench_root});

    debug_log.log("bench_indexing: reset fixture", .{});
    std.fs.cwd().deleteTree(".cog") catch |err| if (err != error.FileNotFound) return err;
    for (0..SOURCE_FILE_COUNT / 8) |i| {
        var package_name_buf: [16]u8 = undefined;
        const package_name = try std.fmt.bufPrint(&package_name_buf, "pkg_{d:0>2}", .{i});
        std.fs.cwd().deleteTree(package_name) catch |err| if (err != error.FileNotFound) return err;
    }
    try writeSyntheticCorpus(allocator);
    const index_path = try std.fs.path.join(allocator, &.{ bench_root, ".cog", "index.scip" });
    defer allocator.free(index_path);

    const first = try runFullIndex(allocator, index_path);
    const reindex_ns = try runReindexBatch(allocator, index_path);
    const after_reindex = try snapshotIndex(allocator, index_path);
    if (!std.mem.eql(u8, &first[0].hash, &after_reindex.hash) or first[0].encoded_bytes != after_reindex.encoded_bytes) {
        fail("indexing benchmark reindex changed deterministic bytes\n", .{});
    }

    std.fs.cwd().deleteTree(".cog") catch |err| return err;
    const second = try runFullIndex(allocator, index_path);
    if (!std.mem.eql(u8, &first[0].hash, &second[0].hash) or first[0].encoded_bytes != second[0].encoded_bytes) {
        fail("indexing benchmark two-run hash regression\n", .{});
    }

    const load_query = try runLoadAndQueries(allocator);
    printReport(second[0], .{
        .full_index_ns = second[1],
        .reindex_ns = reindex_ns,
        .load_cache_ns = load_query[0],
        .query_ns = load_query[1],
        .query_bytes = load_query[2],
    });
}
