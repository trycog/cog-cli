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
};

pub const ManifestFile = struct {
    version: u32,
    entries: []Entry,
};

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
/// is recoverable provenance, not index data.
pub fn write(allocator: std.mem.Allocator, cog_dir: std.fs.Dir, entries: []const Entry) bool {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var stringify: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    stringify.write(ManifestFile{
        .version = manifest_version,
        .entries = @constCast(entries),
    }) catch |err| {
        debug_log.log("index_manifest.write: encode failed: {s}", .{@errorName(err)});
        return false;
    };
    aw.writer.writeByte('\n') catch return false;

    fs_util.writeFileAtomic(cog_dir, allocator, manifest_basename, aw.writer.buffered()) catch |err| {
        debug_log.log("index_manifest.write: write failed: {s}", .{@errorName(err)});
        return false;
    };
    debug_log.log("index_manifest.write: entries={d}", .{entries.len});
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

    const entries = [_]Entry{
        .{ .path = "src/main.zig", .size = 123, .mtime_ns = 1_755_000_000_123_456_789 },
        .{ .path = "src/util.zig", .size = 456, .mtime_ns = 1_755_000_000_987_654_321 },
    };
    try std.testing.expect(write(allocator, tmp.dir, &entries));

    // Configuration files are always pretty-printed, never minified.
    const raw = try tmp.dir.readFileAlloc(allocator, manifest_basename, 4096);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\n  \"version\": 1") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "\n"));

    var loaded = load(allocator, tmp.dir) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.value.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.value.entries[0].path);
    try std.testing.expectEqual(@as(u64, 123), loaded.value.entries[0].size);
    try std.testing.expectEqual(@as(i128, 1_755_000_000_123_456_789), loaded.value.entries[0].mtime_ns);
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
