const std = @import("std");
const paths = @import("../../paths.zig");

/// Embedded Java source for the JDI DAP server.
/// At runtime, this is written to a temp file and compiled with javac.
const jdi_server_source = @embedFile("jdi_dap_server/JdiDapServer.java");

/// Return the path to JdiDapServer.class if it exists, or null.
pub fn findJdiServer(allocator: std.mem.Allocator) ?[]const u8 {
    const config_dir = paths.getGlobalConfigDir(allocator) catch return null;
    defer allocator.free(config_dir);
    const class_path = std.fs.path.join(allocator, &.{ config_dir, "jdi-dap", "JdiDapServer.class" }) catch return null;
    const file = std.fs.openFileAbsolute(class_path, .{}) catch {
        allocator.free(class_path);
        return null;
    };
    file.close();
    // Return the directory (classpath), not the .class file path
    allocator.free(class_path);
    return std.fs.path.join(allocator, &.{ config_dir, "jdi-dap" }) catch return null;
}

/// Ensure JdiDapServer.class is compiled and cached.
/// Returns the classpath directory containing the compiled class.
pub fn ensureJdiServer(allocator: std.mem.Allocator) ![]const u8 {
    // Check if already compiled
    if (findJdiServer(allocator)) |cp| return cp;

    // Get config dir
    const config_dir = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir);

    // Create ~/.config/cog/jdi-dap/
    const jdi_dir = try std.fs.path.join(allocator, &.{ config_dir, "jdi-dap" });
    defer allocator.free(jdi_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(jdi_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write embedded Java source to a temp file
    const java_path = try std.fs.path.join(allocator, &.{ jdi_dir, "JdiDapServer.java" });
    defer allocator.free(java_path);

    {
        const file = try std.fs.createFileAbsolute(java_path, .{});
        defer file.close();
        try file.writeAll(jdi_server_source);
    }

    // Compile with javac
    var javac = std.process.Child.init(&.{ "javac", "-g", "-d", jdi_dir, java_path }, allocator);
    javac.stdin_behavior = .Ignore;
    javac.stdout_behavior = .Ignore;
    javac.stderr_behavior = .Ignore;
    javac.spawn() catch return error.JavacNotFound;
    const term = javac.wait() catch return error.JdiCompileFailed;
    if (term.Exited != 0) return error.JdiCompileFailed;

    // Clean up the .java source file (keep only .class)
    std.fs.deleteFileAbsolute(java_path) catch {};

    // Verify .class exists and return classpath dir
    return findJdiServer(allocator) orelse error.JdiCompileFailed;
}
