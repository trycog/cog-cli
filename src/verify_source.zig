const std = @import("std");
const debug_log = @import("debug_log.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

const HashSnapshot = struct {
    digest: Digest,
    stat: std.fs.File.Stat,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 6) return error.InvalidArguments;

    const archive_path = args[1];
    const expected_hex = args[2];
    const max_bytes = std.fmt.parseInt(u64, args[3], 10) catch return error.InvalidSizeLimit;
    const destination = args[4];
    const tar_path = args[5];
    const expected = parseSha256(expected_hex) catch |err| {
        debug_log.log("verify_source: invalid expected SHA-256 for {s}: {s}", .{ archive_path, @errorName(err) });
        return err;
    };

    debug_log.log("verify_source: opening {s} with {d}-byte ceiling", .{ archive_path, max_bytes });
    const archive = try std.fs.cwd().openFile(archive_path, .{});
    defer archive.close();

    // Once open, remove the name entirely. Verification and extraction below
    // both consume this same descriptor, so no public pathname can be swapped
    // between the checksum decision and tar.
    try std.fs.cwd().deleteFile(archive_path);
    debug_log.log("verify_source: unlinked opened archive {s}", .{archive_path});

    const snapshot = hashOpenFileBounded(archive, max_bytes) catch |err| {
        debug_log.log("verify_source: rejected {s}: {s}", .{ archive_path, @errorName(err) });
        return err;
    };
    if (!std.mem.eql(u8, &snapshot.digest, &expected)) {
        const actual_hex = std.fmt.bytesToHex(snapshot.digest, .lower);
        debug_log.log("verify_source: SHA-256 mismatch for {s}; expected {s}, got {s}", .{ archive_path, expected_hex, &actual_hex });
        std.debug.print("SHA-256 mismatch for {s}: expected {s}, got {s}\n", .{ archive_path, expected_hex, &actual_hex });
        return error.ChecksumMismatch;
    }

    try validateStableFile(archive, snapshot.stat);
    debug_log.log("verify_source: spawning {s} for verified archive extraction into {s}", .{ tar_path, destination });
    try extractOpenArchive(allocator, archive, snapshot.stat, destination, tar_path);
    debug_log.log("verify_source: verified and extracted {s}", .{archive_path});
}

fn sha256File(path: []const u8) !Digest {
    return sha256FileBounded(path, std.math.maxInt(u64));
}

fn sha256FileBounded(path: []const u8, max_bytes: u64) !Digest {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return (try hashOpenFileBounded(file, max_bytes)).digest;
}

fn hashOpenFileBounded(file: std.fs.File, max_bytes: u64) !HashSnapshot {
    const initial_stat = try file.stat();
    if (initial_stat.kind != .file) return error.NotRegularFile;
    if (initial_stat.size > max_bytes) return error.ArchiveTooLarge;

    try file.seekTo(0);
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(&file_buffer);
    var chunk: [16 * 1024]u8 = undefined;
    var total_read: u64 = 0;
    var hasher = Sha256.init(.{});
    while (true) {
        const read_len = try reader.interface.readSliceShort(&chunk);
        if (read_len == 0) break;
        total_read = std.math.add(u64, total_read, read_len) catch return error.ArchiveTooLarge;
        if (total_read > max_bytes) return error.ArchiveTooLarge;
        hasher.update(chunk[0..read_len]);
    }

    const final_stat = try file.stat();
    if (!sameFileIdentity(initial_stat, final_stat) or total_read != final_stat.size) {
        return error.ArchiveChangedDuringVerification;
    }
    return .{ .digest = hasher.finalResult(), .stat = final_stat };
}

fn validateStableFile(file: std.fs.File, hash_time_stat: std.fs.File.Stat) !void {
    const current_stat = try file.stat();
    if (!sameFileIdentity(hash_time_stat, current_stat)) {
        return error.ArchiveChangedAfterVerification;
    }
}

fn extractOpenArchive(
    allocator: std.mem.Allocator,
    archive: std.fs.File,
    hash_time_stat: std.fs.File.Stat,
    destination: []const u8,
    tar_path: []const u8,
) !void {
    try validateStableFile(archive, hash_time_stat);
    try archive.seekTo(0);

    var child = std.process.Child.init(&.{ tar_path, "xzf", "-", "-C", destination }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const child_stdin = child.stdin.?;
    child.stdin = null;
    var stdin_open = true;
    defer if (stdin_open) child_stdin.close();

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = archive.readerStreaming(&file_buffer);
    var chunk: [16 * 1024]u8 = undefined;
    var total_read: u64 = 0;
    while (true) {
        const read_len = reader.interface.readSliceShort(&chunk) catch |err| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return err;
        };
        if (read_len == 0) break;
        total_read = std.math.add(u64, total_read, read_len) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.ArchiveChangedAfterVerification;
        };
        if (total_read > hash_time_stat.size) {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.ArchiveChangedAfterVerification;
        }
        child_stdin.writeAll(chunk[0..read_len]) catch |err| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return err;
        };
    }
    child_stdin.close();
    stdin_open = false;

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ExtractionFailed,
        else => return error.ExtractionFailed,
    }
    if (total_read != hash_time_stat.size) return error.ArchiveChangedAfterVerification;
    try validateStableFile(archive, hash_time_stat);
}

fn sameFileIdentity(a: std.fs.File.Stat, b: std.fs.File.Stat) bool {
    return a.kind == .file and
        b.kind == .file and
        a.inode == b.inode and
        a.size == b.size and
        a.mtime == b.mtime and
        a.ctime == b.ctime;
}

fn parseSha256(hex: []const u8) !Digest {
    if (hex.len != Sha256.digest_length * 2) return error.InvalidChecksum;
    var digest: Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidChecksum;
    return digest;
}

test "parseSha256 accepts recorded lowercase digest" {
    const expected = [_]u8{0xab} ** Sha256.digest_length;
    try std.testing.expectEqual(expected, try parseSha256("abababababababababababababababababababababababababababababababab"));
}

test "parseSha256 rejects malformed digest" {
    try std.testing.expectError(error.InvalidChecksum, parseSha256("not-a-sha256"));
}

test "sha256File detects a one-byte mutation" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "original" });
    const original_path = try temp_dir.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(original_path);
    const original = try sha256File(original_path);

    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "originaL" });
    const mutated = try sha256File(original_path);
    try std.testing.expect(!std.mem.eql(u8, &original, &mutated));
}

test "sha256FileBounded rejects oversized archives before hashing" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "oversized" });
    const path = try temp_dir.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.ArchiveTooLarge, sha256FileBounded(path, 8));
}

test "sha256FileBounded rejects non-regular input" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makeDir("source");
    const path = try temp_dir.dir.realpathAlloc(std.testing.allocator, "source");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.NotRegularFile, sha256FileBounded(path, 8));
}

test "sameFileIdentity rejects a replacement inode" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "original" });
    const original = try temp_dir.dir.openFile("source", .{});
    defer original.close();
    const original_stat = try original.stat();

    try temp_dir.dir.writeFile(.{ .sub_path = "replacement", .data = "original" });
    try temp_dir.dir.rename("replacement", "source");
    const replacement = try temp_dir.dir.openFile("source", .{});
    defer replacement.close();
    const replacement_stat = try replacement.stat();

    try std.testing.expect(!sameFileIdentity(original_stat, replacement_stat));
}

test "post-hash growth is rejected before extraction" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "verified" });
    const file = try temp_dir.dir.openFile("source", .{ .mode = .read_write });
    defer file.close();
    const snapshot = try hashOpenFileBounded(file, 1024);

    try file.seekFromEnd(0);
    try file.writeAll("-growth");
    try std.testing.expectError(
        error.ArchiveChangedAfterVerification,
        validateStableFile(file, snapshot.stat),
    );
}

test "extraction streams the verified descriptor after path replacement" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "verified archive bytes" });
    const archive = try temp_dir.dir.openFile("source", .{});
    defer archive.close();
    try temp_dir.dir.deleteFile("source");
    const snapshot = try hashOpenFileBounded(archive, 1024);

    // Recreating the removed public name cannot redirect extraction away from
    // the already-open descriptor.
    try temp_dir.dir.writeFile(.{ .sub_path = "source", .data = "attacker archive bytes" });

    const script =
        \\#!/bin/sh
        \\cat > "$0.capture"
    ;
    try temp_dir.dir.writeFile(.{ .sub_path = "fake-tar", .data = script });
    const fake_tar = try temp_dir.dir.openFile("fake-tar", .{ .mode = .read_write });
    try fake_tar.chmod(0o700);
    fake_tar.close();

    const root = try temp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const tar_path = try temp_dir.dir.realpathAlloc(std.testing.allocator, "fake-tar");
    defer std.testing.allocator.free(tar_path);
    try extractOpenArchive(std.testing.allocator, archive, snapshot.stat, root, tar_path);

    const captured = try temp_dir.dir.readFileAlloc(std.testing.allocator, "fake-tar.capture", 1024);
    defer std.testing.allocator.free(captured);
    try std.testing.expectEqualStrings("verified archive bytes", captured);
}
