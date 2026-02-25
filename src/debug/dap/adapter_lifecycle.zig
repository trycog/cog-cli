const std = @import("std");
const curl = @import("../../curl.zig");
const paths = @import("../../paths.zig");
const extensions = @import("../../extensions.zig");

/// Embedded Java source for the JDI DAP server (used by compile_embedded method).
const jdi_server_source = @embedFile("jdi_dap_server/JdiDapServer.java");

// ── Generic Adapter Installation ────────────────────────────────────────

/// Ensure the debug adapter is available, installing if necessary.
/// Returns the adapter base path (directory containing the entry point).
/// For system adapters, returns an empty string (adapter is expected on PATH).
pub fn ensureAdapter(allocator: std.mem.Allocator, install: extensions.AdapterInstall) ![]const u8 {
    return switch (install.method) {
        .system => "",
        .github_release => ensureGithubRelease(allocator, install),
        .compile_embedded => ensureCompileEmbedded(allocator, install),
    };
}

/// Download and install a debug adapter from a GitHub release.
fn ensureGithubRelease(allocator: std.mem.Allocator, install: extensions.AdapterInstall) ![]const u8 {
    const config_dir = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir);

    // Check if already installed by looking for the entry_point file
    const entry_path = try std.fs.path.join(allocator, &.{ config_dir, install.entry_point });
    {
        const file = std.fs.openFileAbsolute(entry_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(entry_path);
                // Need to download — fall through
                return downloadGithubRelease(allocator, config_dir, install);
            },
            else => {
                allocator.free(entry_path);
                return err;
            },
        };
        file.close();
    }

    // Already installed — return the directory containing the entry point
    allocator.free(entry_path);
    return std.fs.path.join(allocator, &.{ config_dir, install.install_dir });
}

fn downloadGithubRelease(allocator: std.mem.Allocator, config_dir: []const u8, install: extensions.AdapterInstall) ![]const u8 {
    const repo = install.repo orelse return error.MissingRepo;
    const version = install.version orelse return error.MissingVersion;
    const asset = install.asset_pattern orelse return error.MissingAsset;

    // Build URL: https://github.com/{repo}/releases/download/{version}/{asset}
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/{s}", .{ repo, version, asset });
    defer allocator.free(url);

    // Ensure config dir exists
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Download the asset
    const response = try curl.get(allocator, url, &.{});
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.DownloadFailed;

    // Write to temp file
    const tarball_path = try std.fs.path.join(allocator, &.{ config_dir, asset });
    defer allocator.free(tarball_path);

    {
        const file = try std.fs.createFileAbsolute(tarball_path, .{});
        defer file.close();
        try file.writeAll(response.body);
    }

    // Extract based on format
    const format = install.extract_format orelse "tar.gz";
    if (std.mem.eql(u8, format, "tar.gz")) {
        var tar = std.process.Child.init(&.{ "tar", "xzf", tarball_path, "-C", config_dir }, allocator);
        tar.stdin_behavior = .Ignore;
        tar.stdout_behavior = .Ignore;
        tar.stderr_behavior = .Ignore;
        try tar.spawn();
        const term = try tar.wait();
        if (term.Exited != 0) return error.ExtractFailed;
    } else if (std.mem.eql(u8, format, "zip")) {
        var unzip = std.process.Child.init(&.{ "unzip", "-o", tarball_path, "-d", config_dir }, allocator);
        unzip.stdin_behavior = .Ignore;
        unzip.stdout_behavior = .Ignore;
        unzip.stderr_behavior = .Ignore;
        try unzip.spawn();
        const term = try unzip.wait();
        if (term.Exited != 0) return error.ExtractFailed;
    } else {
        return error.UnsupportedFormat;
    }

    // Clean up the downloaded archive
    std.fs.deleteFileAbsolute(tarball_path) catch {};

    // Verify installation
    const entry_path = try std.fs.path.join(allocator, &.{ config_dir, install.entry_point });
    const file = std.fs.openFileAbsolute(entry_path, .{}) catch {
        allocator.free(entry_path);
        return error.InstallFailed;
    };
    file.close();
    allocator.free(entry_path);

    return std.fs.path.join(allocator, &.{ config_dir, install.install_dir });
}

/// Compile an embedded source file and cache the result.
fn ensureCompileEmbedded(allocator: std.mem.Allocator, install: extensions.AdapterInstall) ![]const u8 {
    const config_dir = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir);

    // Check if already compiled by looking for the entry_point file
    const entry_path = try std.fs.path.join(allocator, &.{ config_dir, install.entry_point });
    {
        const file = std.fs.openFileAbsolute(entry_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(entry_path);
                // Need to compile — fall through
                return compileEmbeddedJdi(allocator, config_dir, install);
            },
            else => {
                allocator.free(entry_path);
                return err;
            },
        };
        file.close();
    }

    // Already compiled — return the install directory
    allocator.free(entry_path);
    return std.fs.path.join(allocator, &.{ config_dir, install.install_dir });
}

fn compileEmbeddedJdi(allocator: std.mem.Allocator, config_dir: []const u8, install: extensions.AdapterInstall) ![]const u8 {
    const install_dir = try std.fs.path.join(allocator, &.{ config_dir, install.install_dir });
    defer allocator.free(install_dir);

    // Ensure directories exist
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(install_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write embedded Java source
    const java_path = try std.fs.path.join(allocator, &.{ install_dir, "JdiDapServer.java" });
    defer allocator.free(java_path);

    {
        const file = try std.fs.createFileAbsolute(java_path, .{});
        defer file.close();
        try file.writeAll(jdi_server_source);
    }

    // Compile with javac
    var javac = std.process.Child.init(&.{ "javac", "-g", "-d", install_dir, java_path }, allocator);
    javac.stdin_behavior = .Ignore;
    javac.stdout_behavior = .Ignore;
    javac.stderr_behavior = .Ignore;
    javac.spawn() catch return error.JavacNotFound;
    const term = javac.wait() catch return error.JdiCompileFailed;
    if (term.Exited != 0) return error.JdiCompileFailed;

    // Clean up source file
    std.fs.deleteFileAbsolute(java_path) catch {};

    // Verify and return
    const entry_path = try std.fs.path.join(allocator, &.{ config_dir, install.entry_point });
    const file = std.fs.openFileAbsolute(entry_path, .{}) catch {
        allocator.free(entry_path);
        return error.JdiCompileFailed;
    };
    file.close();
    allocator.free(entry_path);

    return std.fs.path.join(allocator, &.{ config_dir, install.install_dir });
}

// ── Generic Dependency Checking ─────────────────────────────────────────

/// Check that all required dependencies are available.
/// Returns the error_message of the first missing dependency, or null if all are present.
pub fn checkDependencies(allocator: std.mem.Allocator, deps: []const extensions.DependencyCheck) ?[]const u8 {
    for (deps) |dep| {
        // Build argv: [command] ++ check_args
        const argv_len = 1 + dep.check_args.len;
        const argv = allocator.alloc([]const u8, argv_len) catch continue;
        defer allocator.free(argv);
        argv[0] = dep.command;
        @memcpy(argv[1..], dep.check_args);

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return dep.error_message;
        const term = child.wait() catch return dep.error_message;
        if (term.Exited != 0) return dep.error_message;
    }
    return null;
}

// ── Generic Port Detection ──────────────────────────────────────────────

/// Detect a port number from adapter stdout output using a configurable prefix.
/// Looks for the prefix string, then extracts the port after the last colon.
pub fn detectPortFromStdout(output: []const u8, prefix: []const u8) ?u16 {
    const idx = std.mem.indexOf(u8, output, prefix) orelse return null;
    const after = output[idx + prefix.len ..];
    // Find the last colon (host:port format)
    const colon_idx = std.mem.lastIndexOfScalar(u8, after, ':') orelse return null;
    const port_str = after[colon_idx + 1 ..];
    // Trim trailing whitespace/newline
    const trimmed = std.mem.trimRight(u8, port_str, " \t\r\n");
    return std.fmt.parseInt(u16, trimmed, 10) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "detectPortFromStdout parses valid output" {
    const output = "Debug server listening at 127.0.0.1:54321\n";
    const port = detectPortFromStdout(output, "Debug server listening at ");
    try std.testing.expectEqual(@as(?u16, 54321), port);
}

test "detectPortFromStdout returns null for garbage" {
    try std.testing.expect(detectPortFromStdout("random output", "Debug server listening at ") == null);
}

test "detectPortFromStdout handles port at end without newline" {
    const output = "Debug server listening at 127.0.0.1:8080";
    const port = detectPortFromStdout(output, "Debug server listening at ");
    try std.testing.expectEqual(@as(?u16, 8080), port);
}

test "detectPortFromStdout with custom prefix" {
    const output = "Listening on port 0.0.0.0:9229\n";
    const port = detectPortFromStdout(output, "Listening on port ");
    try std.testing.expectEqual(@as(?u16, 9229), port);
}
