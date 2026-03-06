const std = @import("std");
const debug_log = @import("debug_log.zig");

/// Find .cog directory by walking up from cwd.
/// Stops at project boundaries (.git) to avoid escaping the current project.
/// Returns the absolute path to the .cog directory.
pub fn findCogDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoCogDir;

    var current = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(current);

    while (true) {
        debug_log.log("findCogDir: checking {s}", .{current});
        var dir = std.fs.openDirAbsolute(current, .{}) catch {
            // Can't open dir, stop walking
            break;
        };
        defer dir.close();

        // Check for .cog/ directory
        const has_cog_dir = blk: {
            var cog_dir = dir.openDir(".cog", .{}) catch break :blk false;
            cog_dir.close();
            break :blk true;
        };
        if (has_cog_dir) {
            debug_log.log("findCogDir: found at {s}/.cog", .{current});
            return std.fmt.allocPrint(allocator, "{s}/.cog", .{current});
        }

        // Stop at project root (.git boundary) — don't escape into parent projects
        const has_git = blk: {
            var git_dir = dir.openDir(".git", .{}) catch break :blk false;
            git_dir.close();
            break :blk true;
        };
        if (has_git) break;

        if (std.mem.eql(u8, current, home)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;
        const new_current = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = new_current;
    }

    return error.NoCogDir;
}

/// Create .cog/ in cwd if it doesn't exist, with an empty settings.json.
/// Used by code/index to bootstrap without prior `cog init`.
pub fn findOrCreateCogDir(allocator: std.mem.Allocator) ![]const u8 {
    // Always operate on cwd — don't walk up
    std.fs.cwd().makeDir(".cog") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.NoCogDir,
    };

    // Create empty settings.json if it doesn't exist
    var cog_dir = std.fs.cwd().openDir(".cog", .{}) catch return error.NoCogDir;
    defer cog_dir.close();
    if (cog_dir.openFile("settings.json", .{})) |f| {
        f.close();
    } else |_| {
        // Doesn't exist — create it
        const f = cog_dir.createFile("settings.json", .{}) catch return error.NoCogDir;
        defer f.close();
        f.writeAll("{}\n") catch {};
    }

    return std.fs.cwd().realpathAlloc(allocator, ".cog");
}

/// Get the global config directory: ~/.config/cog/
pub fn getGlobalConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/cog", .{home});
}
