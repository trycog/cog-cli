//! Provenance manifest for the SCIP index.
//!
//! Records the size and mtime of every managed document at index-write time
//! so a reconcile pass can cheaply detect drift — files that changed while no
//! watcher was running (edits between sessions, branch switches, pulls). The
//! manifest is advisory: a missing or malformed manifest never fails an index
//! operation, it only forces the next reconcile to fall back to a full resync.

const std = @import("std");
const debug_log = @import("debug_log.zig");
const fs_util = @import("fs_util.zig");

pub const manifest_basename = "index-manifest.json";
pub const manifest_version: u32 = 1;
const max_manifest_bytes: usize = 64 * 1024 * 1024;

pub const Entry = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
    // Content hash (XxHash64) confirming stat-level drift: checkout churn
    // restores files with fresh mtimes but identical bytes. Null when the
    // content was unavailable at write time or the manifest predates hashing.
    hash: ?u64 = null,
};

pub const ManifestFile = struct {
    version: u32,
    // The configured index pattern set at write time, so reconciliation works
    // for projects indexed with explicit CLI patterns and no settings entry.
    patterns: []const []const u8 = &.{},
    external_roots: []const []const u8 = &.{},
    // Resolved git HEAD at write time; enables the candidate fast path.
    head_commit: ?[]const u8 = null,
    entries: []Entry,
};

pub fn hashContent(bytes: []const u8) u64 {
    return std.hash.XxHash64.hash(0, bytes);
}

const max_hashed_file_bytes: usize = 256 * 1024 * 1024;

/// Hash a file's content by absolute or root-relative physical path. Null on
/// any failure — the entry then carries stat evidence only.
pub fn hashPhysicalFile(allocator: std.mem.Allocator, physical_path: []const u8) ?u64 {
    const content = std.fs.cwd().readFileAlloc(allocator, physical_path, max_hashed_file_bytes) catch |err| {
        debug_log.log("index_manifest.hashPhysicalFile: {s}: {s}", .{ physical_path, @errorName(err) });
        return null;
    };
    defer allocator.free(content);
    return hashContent(content);
}

pub const Loaded = std.json.Parsed(ManifestFile);

/// Load the manifest from a Cog directory. Any failure — missing file,
/// malformed JSON, version mismatch — returns null: the caller treats the
/// index provenance as unknown and reconciles with a full resync.
pub fn load(allocator: std.mem.Allocator, cog_dir: std.fs.Dir) ?Loaded {
    const data = cog_dir.readFileAlloc(allocator, manifest_basename, max_manifest_bytes) catch |err| {
        debug_log.log("index_manifest.load: unavailable: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(data);

    // alloc_always: parsed strings must not borrow `data`, which is freed
    // before the caller sees the result.
    const parsed = std.json.parseFromSlice(ManifestFile, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        debug_log.log("index_manifest.load: malformed manifest: {s}", .{@errorName(err)});
        return null;
    };
    if (parsed.value.version != manifest_version) {
        debug_log.log("index_manifest.load: unsupported version={d}", .{parsed.value.version});
        parsed.deinit();
        return null;
    }
    debug_log.log("index_manifest.load: entries={d}", .{parsed.value.entries.len});
    return parsed;
}

/// Atomically write the manifest into a Cog directory as pretty-printed JSON.
/// Returns false on failure; callers log and continue, because the manifest
/// is recoverable provenance, not index data. The version field is always
/// stamped by this module.
pub fn write(allocator: std.mem.Allocator, cog_dir: std.fs.Dir, manifest: ManifestFile) bool {
    var stamped = manifest;
    stamped.version = manifest_version;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var stringify: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    stringify.write(stamped) catch |err| {
        debug_log.log("index_manifest.write: encode failed: {s}", .{@errorName(err)});
        return false;
    };
    aw.writer.writeByte('\n') catch return false;

    fs_util.writeFileAtomic(cog_dir, allocator, manifest_basename, aw.writer.buffered()) catch |err| {
        debug_log.log("index_manifest.write: write failed: {s}", .{@errorName(err)});
        return false;
    };
    debug_log.log("index_manifest.write: entries={d} patterns={d}", .{ stamped.entries.len, stamped.patterns.len });
    return true;
}

/// Produce a manifest entry by statting a path relative to the project root.
/// Returns null when the file cannot be statted; the reconcile pass then
/// treats it as drifted, which is the safe direction.
pub fn statFile(project_root: std.fs.Dir, path: []const u8) ?Entry {
    const stat = project_root.statFile(path) catch |err| {
        debug_log.log("index_manifest.statFile: {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
    return .{ .path = path, .size = stat.size, .mtime_ns = stat.mtime };
}

/// Produce a manifest entry keyed by a logical path but statted through its
/// physical location — external-root documents live outside the project and
/// their `@external/...` aliases cannot be statted from the root.
pub fn statPhysicalFile(physical_path: []const u8, logical_path: []const u8) ?Entry {
    const stat = std.fs.cwd().statFile(physical_path) catch |err| {
        debug_log.log("index_manifest.statPhysicalFile: {s}: {s}", .{ physical_path, @errorName(err) });
        return null;
    };
    return .{ .path = logical_path, .size = stat.size, .mtime_ns = stat.mtime };
}

test "manifest round-trips entries through pretty-printed JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var entries = [_]Entry{
        .{ .path = "src/main.zig", .size = 123, .mtime_ns = 1_755_000_000_123_456_789, .hash = 0xdead_beef },
        .{ .path = "src/util.zig", .size = 456, .mtime_ns = 1_755_000_000_987_654_321 },
    };
    var patterns = [_][]const u8{"**/*.zig"};
    try std.testing.expect(write(allocator, tmp.dir, .{
        .version = manifest_version,
        .patterns = &patterns,
        .head_commit = "0123456789abcdef",
        .entries = &entries,
    }));

    // Configuration files are always pretty-printed, never minified.
    const raw = try tmp.dir.readFileAlloc(allocator, manifest_basename, 8192);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\n  \"version\": 1") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "\n"));

    var loaded = load(allocator, tmp.dir) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.value.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.value.entries[0].path);
    try std.testing.expectEqual(@as(u64, 123), loaded.value.entries[0].size);
    try std.testing.expectEqual(@as(i128, 1_755_000_000_123_456_789), loaded.value.entries[0].mtime_ns);
    try std.testing.expectEqual(@as(?u64, 0xdead_beef), loaded.value.entries[0].hash);
    try std.testing.expectEqual(@as(?u64, null), loaded.value.entries[1].hash);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.patterns.len);
    try std.testing.expectEqualStrings("**/*.zig", loaded.value.patterns[0]);
    try std.testing.expectEqualStrings("0123456789abcdef", loaded.value.head_commit.?);
}

test "manifests without the extended fields load with defaults" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = manifest_basename, .data = 
        \\{
        \\  "version": 1,
        \\  "entries": [
        \\    { "path": "a.go", "size": 10, "mtime_ns": 5 }
        \\  ]
        \\}
    });
    var loaded = load(allocator, tmp.dir) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.value.patterns.len);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.value.head_commit);
    try std.testing.expectEqual(@as(?u64, null), loaded.value.entries[0].hash);
}

test "manifest load tolerates missing, malformed, and mismatched files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(load(allocator, tmp.dir) == null);

    try tmp.dir.writeFile(.{ .sub_path = manifest_basename, .data = "{not json" });
    try std.testing.expect(load(allocator, tmp.dir) == null);

    try tmp.dir.writeFile(.{ .sub_path = manifest_basename, .data = 
        \\{
        \\  "version": 999,
        \\  "entries": []
        \\}
    });
    try std.testing.expect(load(allocator, tmp.dir) == null);
}

test "statFile reports drift-safe null for missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "present.zig", .data = "const a = 1;\n" });
    const entry = statFile(tmp.dir, "present.zig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 13), entry.size);
    try std.testing.expect(statFile(tmp.dir, "absent.zig") == null);
}
