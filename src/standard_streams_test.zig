const std = @import("std");

fn writeStreaming(file: std.fs.File, message: []const u8) !void {
    var buffer: [64]u8 = undefined;
    var writer = file.writerStreaming(&buffer);
    try writer.interface.writeAll(message);
    try writer.interface.flush();
}

test "fresh streaming writers append to a redirected regular file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output = try tmp.dir.createFile("redirected.log", .{ .read = true });
    defer output.close();

    try writeStreaming(output, "first\n");
    try writeStreaming(output, "second\n");
    try output.seekTo(0);

    const contents = try output.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("first\nsecond\n", contents);
}

test "Cog source never uses positional writers for stdout or stderr" {
    var source_dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer source_dir.close();

    var walker = try source_dir.walk(std.testing.allocator);
    defer walker.deinit();

    const positional_stdout = "File.stdout()" ++ ".writer(";
    const positional_stderr = "File.stderr()" ++ ".writer(";
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const file = try entry.dir.openFile(entry.basename, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(std.testing.allocator, 2 * 1024 * 1024);
        defer std.testing.allocator.free(contents);

        if (std.mem.indexOf(u8, contents, positional_stdout) != null or
            std.mem.indexOf(u8, contents, positional_stderr) != null)
        {
            std.debug.print("positional standard-stream writer remains in src/{s}\n", .{entry.path});
            return error.PositionalStandardStreamWriter;
        }
    }
}

test "MCP source never restores the shared raw payload log" {
    const source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "src/mcp.zig", 4 * 1024 * 1024);
    defer std.testing.allocator.free(source);

    const forbidden_path = "/tmp/" ++ "cog-mcp.log";
    try std.testing.expect(std.mem.indexOf(u8, source, forbidden_path) == null);
}
