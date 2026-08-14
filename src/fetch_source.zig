const std = @import("std");
const debug_log = @import("debug_log.zig");

const default_max_bytes: u64 = 64 * 1024 * 1024;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 5) return error.InvalidArguments;

    const url = args[1];
    const archive_path = args[2];
    const max_bytes = std.fmt.parseInt(u64, args[3], 10) catch return error.InvalidSizeLimit;
    const curl_path = args[4];

    debug_log.log("fetch_source: spawning curl for {s}", .{url});
    var child = std.process.Child.init(&.{
        curl_path,
        // curl only honors --disable as a curlrc guard when it is first.
        "--disable",
        "--fail",
        "--location",
        "--silent",
        "--show-error",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--max-redirs",
        "3",
        "--connect-timeout",
        "15",
        "--max-time",
        "180",
        "--max-filesize",
        args[3],
        url,
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    debug_log.log("fetch_source: creating private archive {s}", .{archive_path});
    var archive = try std.fs.cwd().createFile(archive_path, .{
        .exclusive = true,
        .mode = 0o600,
    });
    var archive_open = true;
    defer if (archive_open) archive.close();
    errdefer std.fs.cwd().deleteFile(archive_path) catch {};

    const stdout = child.stdout.?;
    child.stdout = null;
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = stdout.readerStreaming(&file_buffer);
    var archive_buffer: [16 * 1024]u8 = undefined;
    var writer = archive.writer(&archive_buffer);
    const total = copyBounded(&reader.interface, &writer.interface, max_bytes) catch |err| {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return err;
    };
    try writer.interface.flush();
    archive.close();
    archive_open = false;

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    child.stderr = null;
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            if (stderr.len > 0) try std.fs.File.stderr().writeAll(stderr);
            return error.DownloadFailed;
        },
        else => return error.DownloadFailed,
    }
    debug_log.log("fetch_source: wrote {d} bytes to {s}", .{ total, archive_path });
}

test "stream copy rejects a byte over the archive ceiling" {
    var source_reader = std.Io.Reader.fixed("123456789");
    var destination: [16]u8 = undefined;
    var destination_writer = std.Io.Writer.fixed(&destination);

    try std.testing.expectError(error.ArchiveTooLarge, copyBounded(&source_reader, &destination_writer, 8));
}

fn copyBounded(reader: *std.Io.Reader, writer: *std.Io.Writer, max_bytes: u64) !u64 {
    var chunk: [16 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const read_len = try reader.readSliceShort(&chunk);
        if (read_len == 0) break;
        total = std.math.add(u64, total, read_len) catch return error.ArchiveTooLarge;
        if (total > max_bytes) return error.ArchiveTooLarge;
        try writer.writeAll(chunk[0..read_len]);
    }
    return total;
}

test "default archive ceiling is 64 MiB" {
    try std.testing.expectEqual(@as(u64, 67_108_864), default_max_bytes);
}
