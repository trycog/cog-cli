const std = @import("std");
const curl = @import("../../curl.zig");
const paths = @import("../../paths.zig");

/// Version of vscode-js-debug to download
const js_debug_version = "v1.105.0";
const js_debug_tarball = "js-debug-dap-" ++ js_debug_version ++ ".tar.gz";
const js_debug_url = "https://github.com/microsoft/vscode-js-debug/releases/download/" ++ js_debug_version ++ "/" ++ js_debug_tarball;

/// Return the path to dapDebugServer.js if it exists, or null.
pub fn findDapServer(allocator: std.mem.Allocator) ?[]const u8 {
    const config_dir = paths.getGlobalConfigDir(allocator) catch return null;
    defer allocator.free(config_dir);
    const path = std.fs.path.join(allocator, &.{ config_dir, "js-debug", "src", "dapDebugServer.js" }) catch return null;
    // Check the file exists
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    file.close();
    return path;
}

/// Ensure dapDebugServer.js is installed, downloading if necessary.
/// Returns the absolute path to dapDebugServer.js.
pub fn ensureDapServer(allocator: std.mem.Allocator) ![]const u8 {
    // Check if already installed
    if (findDapServer(allocator)) |path| return path;

    // Download and extract
    const cog_dir = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(cog_dir);

    // Ensure ~/.config/cog exists
    std.fs.makeDirAbsolute(cog_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Download the tarball
    const response = try curl.get(allocator, js_debug_url, &.{});
    defer allocator.free(response.body);

    if (response.status_code != 200) return error.DownloadFailed;

    // Write tarball to temp file
    const tarball_path = try std.fs.path.join(allocator, &.{ cog_dir, js_debug_tarball });
    defer allocator.free(tarball_path);

    {
        const file = try std.fs.createFileAbsolute(tarball_path, .{});
        defer file.close();
        try file.writeAll(response.body);
    }

    // Extract with tar subprocess
    var tar = std.process.Child.init(&.{ "tar", "xzf", tarball_path, "-C", cog_dir }, allocator);
    tar.stdin_behavior = .Ignore;
    tar.stdout_behavior = .Ignore;
    tar.stderr_behavior = .Ignore;
    try tar.spawn();
    const term = try tar.wait();
    if (term.Exited != 0) return error.ExtractFailed;

    // Clean up tarball
    std.fs.deleteFileAbsolute(tarball_path) catch {};

    // Verify installation
    return findDapServer(allocator) orelse error.InstallFailed;
}

/// Parse the listening port from vscode-js-debug stdout output.
/// Expected format: "Debug server listening at 127.0.0.1:PORT\n"
pub fn parseListeningPort(output: []const u8) ?u16 {
    // Look for the port pattern after the last ':'
    const marker = "Debug server listening at ";
    const idx = std.mem.indexOf(u8, output, marker) orelse return null;
    const after_marker = output[idx + marker.len ..];
    // Find the colon separating host:port
    const colon_idx = std.mem.lastIndexOfScalar(u8, after_marker, ':') orelse return null;
    const port_str = after_marker[colon_idx + 1 ..];
    // Trim trailing whitespace/newline
    const trimmed = std.mem.trimRight(u8, port_str, " \t\r\n");
    return std.fmt.parseInt(u16, trimmed, 10) catch null;
}

test "parseListeningPort parses valid output" {
    const output = "Debug server listening at 127.0.0.1:54321\n";
    const port = parseListeningPort(output);
    try std.testing.expectEqual(@as(?u16, 54321), port);
}

test "parseListeningPort returns null for garbage" {
    try std.testing.expect(parseListeningPort("random output") == null);
}

test "parseListeningPort handles port at end without newline" {
    const output = "Debug server listening at 127.0.0.1:8080";
    const port = parseListeningPort(output);
    try std.testing.expectEqual(@as(?u16, 8080), port);
}
