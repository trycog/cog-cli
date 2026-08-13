const std = @import("std");
const debug_log = @import("debug_log.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const archive_path = args[1];
    const expected_hex = args[2];
    debug_log.log("verify_source: reading {s}", .{archive_path});
    const actual = try sha256File(archive_path);
    const expected = parseSha256(expected_hex) catch |err| {
        debug_log.log("verify_source: invalid expected SHA-256 for {s}: {s}", .{ archive_path, @errorName(err) });
        return err;
    };
    if (!std.mem.eql(u8, &actual, &expected)) {
        const actual_hex = std.fmt.bytesToHex(actual, .lower);
        debug_log.log("verify_source: SHA-256 mismatch for {s}; expected {s}, got {s}", .{ archive_path, expected_hex, &actual_hex });
        std.debug.print("SHA-256 mismatch for {s}: expected {s}, got {s}\n", .{ archive_path, expected_hex, &actual_hex });
        return error.ChecksumMismatch;
    }
    debug_log.log("verify_source: verified {s}", .{archive_path});
}

fn sha256File(path: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(&file_buffer);
    var chunk: [16 * 1024]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const read_len = try reader.interface.readSliceShort(&chunk);
        if (read_len == 0) break;
        hasher.update(chunk[0..read_len]);
    }
    return hasher.finalResult();
}

fn parseSha256(hex: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    if (hex.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return error.InvalidChecksum;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidChecksum;
    return digest;
}

test "parseSha256 accepts recorded lowercase digest" {
    const expected = [_]u8{0xab} ** std.crypto.hash.sha2.Sha256.digest_length;
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
