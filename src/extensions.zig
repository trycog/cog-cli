const std = @import("std");
const paths = @import("paths.zig");

// ANSI styles
const dim = "\x1B[2m";
const reset = "\x1B[0m";

/// Debugger configuration for a language extension.
pub const DebuggerType = enum { native, dap };

pub const AdapterConfig = struct {
    command: []const u8,
    args: []const []const u8,
    transport: []const u8,
};

pub const DebuggerConfig = struct {
    debugger_type: DebuggerType,
    adapter: ?AdapterConfig = null,
    launch_args_template: ?[]const u8 = null,
    boundary_markers: []const []const u8 = &.{},
};

/// An extension definition (either built-in or installed).
pub const Extension = struct {
    name: []const u8,
    file_extensions: []const []const u8,
    /// For built-in: the command fragments. For installed: built from bin path.
    command: []const u8,
    /// Args template with {file} and {output} placeholders.
    args: []const []const u8,
    /// Whether this is an installed (non-built-in) extension.
    installed: bool,
    /// For installed extensions: absolute path to the extension directory.
    path: []const u8,
    /// Optional debugger configuration. Null if extension does not support debugging.
    debugger: ?DebuggerConfig = null,
};

/// Built-in extension definitions compiled into the binary.
pub const builtins = [_]Extension{
    .{
        .name = "scip-go",
        .file_extensions = &.{".go"},
        .command = "scip-go",
        .args = &.{ "{file}", "--output", "{output}" },
        .installed = false,
        .path = "",
        .debugger = .{
            .debugger_type = .dap,
            .adapter = .{
                .command = "dlv",
                .args = &.{ "dap", "--listen", ":{port}" },
                .transport = "tcp",
            },
            .launch_args_template =
            \\{"mode":"debug","program":"{program}"}
            ,
            .boundary_markers = &.{ "_cgo_topofstack", "crosscall2" },
        },
    },
    .{
        .name = "scip-typescript",
        .file_extensions = &.{ ".ts", ".tsx", ".js", ".jsx" },
        .command = "scip-typescript",
        .args = &.{ "index", "--infer-tsconfig", "{file}", "--output", "{output}" },
        .installed = false,
        .path = "",
        .debugger = .{
            .debugger_type = .dap,
            .adapter = .{
                .command = "node",
                .args = &.{ "--inspect=0", "{program}" },
                .transport = "cdp",
            },
        },
    },
    .{
        .name = "scip-python",
        .file_extensions = &.{".py"},
        .command = "scip-python",
        .args = &.{ "index", "{file}", "--output", "{output}" },
        .installed = false,
        .path = "",
        .debugger = .{
            .debugger_type = .dap,
            .adapter = .{
                .command = "python3",
                .args = &.{ "-m", "debugpy", "--listen", ":{port}", "--wait-for-client", "{program}" },
                .transport = "tcp",
            },
        },
    },
    .{
        .name = "scip-java",
        .file_extensions = &.{".java"},
        .command = "scip-java",
        .args = &.{ "{file}", "--output", "{output}" },
        .installed = false,
        .path = "",
        .debugger = .{
            .debugger_type = .dap,
            .adapter = .{
                .command = "java",
                .args = &.{"-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=:{port}"},
                .transport = "tcp",
            },
        },
    },
    .{
        .name = "rust-analyzer",
        .file_extensions = &.{".rs"},
        .command = "rust-analyzer",
        .args = &.{ "scip", "{file}", "{output}" },
        .installed = false,
        .path = "",
        .debugger = .{
            .debugger_type = .native,
        },
    },
};

/// An installed extension loaded from disk.
const InstalledExtension = struct {
    name: []const u8,
    file_extensions: []const []const u8,
    args: []const []const u8,
    bin_path: []const u8,
    ext_dir: []const u8,
};

/// Resolve a file extension to the best matching Extension.
/// Installed extensions override built-ins when they share file extensions.
pub fn resolveByExtension(allocator: std.mem.Allocator, file_ext: []const u8) ?Extension {
    // First check installed extensions
    if (scanInstalled(allocator, file_ext)) |ext| {
        return ext;
    }

    // Fall back to built-ins
    for (&builtins) |*b| {
        for (b.file_extensions) |ext| {
            if (std.mem.eql(u8, ext, file_ext)) {
                return b.*;
            }
        }
    }

    return null;
}

/// Scan installed extensions for one matching the given file extension.
fn scanInstalled(allocator: std.mem.Allocator, file_ext: []const u8) ?Extension {
    const config_dir = paths.getGlobalConfigDir(allocator) catch return null;
    defer allocator.free(config_dir);

    const ext_dir = std.fmt.allocPrint(allocator, "{s}/extensions", .{config_dir}) catch return null;
    defer allocator.free(ext_dir);

    var dir = std.fs.openDirAbsolute(ext_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return null) |entry| {
        if (entry.kind != .directory) continue;

        // Read cog-extension.json from this extension dir
        const manifest_path = std.fmt.allocPrint(allocator, "{s}/{s}/cog-extension.json", .{ ext_dir, entry.name }) catch continue;
        defer allocator.free(manifest_path);

        const manifest = readManifest(allocator, manifest_path) catch continue;

        // Check if this extension handles the given file extension
        for (manifest.file_extensions) |ext| {
            if (std.mem.eql(u8, ext, file_ext)) {
                const bin_path = std.fmt.allocPrint(allocator, "{s}/{s}/bin/{s}", .{ ext_dir, entry.name, manifest.name }) catch continue;

                return Extension{
                    .name = manifest.name,
                    .file_extensions = manifest.file_extensions,
                    .command = bin_path,
                    .args = manifest.args,
                    .installed = true,
                    .path = manifest.ext_dir,
                    .debugger = if (manifest.debugger) |d| d.toConfig() else null,
                };
            }
        }

        // Not a match — free the manifest allocations
        freeManifest(allocator, &manifest);
    }

    return null;
}

const ManifestData = struct {
    name: []const u8,
    file_extensions: []const []const u8,
    args: []const []const u8,
    build_cmd: []const u8,
    ext_dir: []const u8,
    debugger: ?AllocatedDebuggerConfig = null,
};

/// Heap-allocated version of DebuggerConfig for installed extensions.
const AllocatedDebuggerConfig = struct {
    debugger_type: DebuggerType,
    adapter_command: ?[]const u8 = null,
    adapter_args: ?[]const []const u8 = null,
    adapter_transport: ?[]const u8 = null,
    launch_args_template: ?[]const u8 = null,
    boundary_markers: []const []const u8 = &.{},

    fn toConfig(self: *const AllocatedDebuggerConfig) DebuggerConfig {
        return .{
            .debugger_type = self.debugger_type,
            .adapter = if (self.adapter_command) |cmd| AdapterConfig{
                .command = cmd,
                .args = self.adapter_args orelse &.{},
                .transport = self.adapter_transport orelse "stdio",
            } else null,
            .launch_args_template = self.launch_args_template,
            .boundary_markers = self.boundary_markers,
        };
    }
};

fn readManifest(allocator: std.mem.Allocator, path: []const u8) !ManifestData {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidManifest;
    const obj = parsed.value.object;

    const name_val = obj.get("name") orelse return error.InvalidManifest;
    if (name_val != .string) return error.InvalidManifest;
    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    // Parse extensions array
    const ext_val = obj.get("extensions") orelse return error.InvalidManifest;
    if (ext_val != .array) return error.InvalidManifest;
    const file_extensions = try allocator.alloc([]const u8, ext_val.array.items.len);
    var ei: usize = 0;
    errdefer {
        for (file_extensions[0..ei]) |e| allocator.free(e);
        allocator.free(file_extensions);
    }
    for (ext_val.array.items) |item| {
        if (item != .string) return error.InvalidManifest;
        file_extensions[ei] = try allocator.dupe(u8, item.string);
        ei += 1;
    }

    // Parse args array
    const args_val = obj.get("args") orelse return error.InvalidManifest;
    if (args_val != .array) return error.InvalidManifest;
    const args_arr = try allocator.alloc([]const u8, args_val.array.items.len);
    var ai: usize = 0;
    errdefer {
        for (args_arr[0..ai]) |a| allocator.free(a);
        allocator.free(args_arr);
    }
    for (args_val.array.items) |item| {
        if (item != .string) return error.InvalidManifest;
        args_arr[ai] = try allocator.dupe(u8, item.string);
        ai += 1;
    }

    // Parse build command
    const build_val = obj.get("build") orelse return error.InvalidManifest;
    if (build_val != .string) return error.InvalidManifest;
    const build_cmd = try allocator.dupe(u8, build_val.string);

    // Get the directory containing the manifest
    const ext_dir = std.fs.path.dirname(path) orelse "";
    const ext_dir_owned = try allocator.dupe(u8, ext_dir);

    // Parse optional debugger config
    const debugger_config = parseDebuggerConfig(allocator, obj) catch null;

    return .{
        .name = name,
        .file_extensions = file_extensions,
        .args = args_arr,
        .build_cmd = build_cmd,
        .ext_dir = ext_dir_owned,
        .debugger = debugger_config,
    };
}

fn parseDebuggerConfig(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?AllocatedDebuggerConfig {
    const dbg_val = obj.get("debugger") orelse return null;
    if (dbg_val != .object) return null;
    const dbg = dbg_val.object;

    const type_val = dbg.get("type") orelse return null;
    if (type_val != .string) return null;
    const debugger_type: DebuggerType = if (std.mem.eql(u8, type_val.string, "native"))
        .native
    else if (std.mem.eql(u8, type_val.string, "dap"))
        .dap
    else
        return null;

    var result: AllocatedDebuggerConfig = .{
        .debugger_type = debugger_type,
    };

    // Parse adapter
    if (dbg.get("adapter")) |adapter_val| {
        if (adapter_val == .object) {
            const adapter = adapter_val.object;
            if (adapter.get("command")) |cmd| {
                if (cmd == .string) {
                    result.adapter_command = try allocator.dupe(u8, cmd.string);
                }
            }
            if (adapter.get("transport")) |tr| {
                if (tr == .string) {
                    result.adapter_transport = try allocator.dupe(u8, tr.string);
                }
            }
            if (adapter.get("args")) |args_v| {
                if (args_v == .array) {
                    const adapter_args = try allocator.alloc([]const u8, args_v.array.items.len);
                    var idx: usize = 0;
                    for (args_v.array.items) |item| {
                        if (item == .string) {
                            adapter_args[idx] = try allocator.dupe(u8, item.string);
                            idx += 1;
                        }
                    }
                    result.adapter_args = adapter_args[0..idx];
                }
            }
        }
    }

    // Parse launch_args
    if (dbg.get("launch_args")) |la| {
        if (la == .string) {
            result.launch_args_template = try allocator.dupe(u8, la.string);
        }
    }

    // Parse boundary_markers
    if (dbg.get("boundary_markers")) |bm| {
        if (bm == .array) {
            const markers = try allocator.alloc([]const u8, bm.array.items.len);
            var mi: usize = 0;
            for (bm.array.items) |item| {
                if (item == .string) {
                    markers[mi] = try allocator.dupe(u8, item.string);
                    mi += 1;
                }
            }
            result.boundary_markers = markers[0..mi];
        }
    }

    return result;
}

fn freeManifest(allocator: std.mem.Allocator, manifest: *const ManifestData) void {
    allocator.free(manifest.name);
    for (manifest.file_extensions) |e| allocator.free(e);
    allocator.free(manifest.file_extensions);
    for (manifest.args) |a| allocator.free(a);
    allocator.free(manifest.args);
    allocator.free(manifest.build_cmd);
    allocator.free(manifest.ext_dir);
    if (manifest.debugger) |dbg| {
        if (dbg.adapter_command) |c| allocator.free(c);
        if (dbg.adapter_transport) |t| allocator.free(t);
        if (dbg.adapter_args) |args| {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }
        if (dbg.launch_args_template) |l| allocator.free(l);
        for (dbg.boundary_markers) |m| allocator.free(m);
        if (dbg.boundary_markers.len > 0) allocator.free(dbg.boundary_markers);
    }
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printStdout(text: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(text) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

/// Install an extension from a git URL.
/// 1. Extract repo name from URL
/// 2. Clone to ~/.config/cog/extensions/<name>/
/// 3. Read cog-extension.json
/// 4. Run build command
/// 5. Verify binary exists
/// 6. Output JSON result
pub fn installExtension(allocator: std.mem.Allocator, git_url: []const u8) !void {
    // Extract name from URL (last path segment, strip .git)
    var name = std.fs.path.basename(git_url);
    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }
    if (name.len == 0) {
        printErr("error: could not extract extension name from URL\n");
        return error.Explained;
    }

    const config_dir = paths.getGlobalConfigDir(allocator) catch {
        printErr("error: could not determine config directory\n");
        return error.Explained;
    };
    defer allocator.free(config_dir);

    const ext_base = try std.fmt.allocPrint(allocator, "{s}/extensions", .{config_dir});
    defer allocator.free(ext_base);

    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ext_base, name });
    defer allocator.free(ext_dir);

    // Create parent directories
    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("error: failed to create config directory\n");
            return error.Explained;
        },
    };
    std.fs.makeDirAbsolute(ext_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("error: failed to create extensions directory\n");
            return error.Explained;
        },
    };

    // Clone or update the repo
    const already_exists = blk: {
        std.fs.accessAbsolute(ext_dir, .{}) catch break :blk false;
        break :blk true;
    };

    if (already_exists) {
        // Pull latest changes
        const pull_args: []const []const u8 = &.{ "git", "pull" };
        var pull = std.process.Child.init(pull_args, allocator);
        pull.cwd = ext_dir;
        pull.stderr_behavior = .Inherit;
        pull.stdout_behavior = .Inherit;
        try pull.spawn();
        const pull_term = try pull.wait();
        if (pull_term.Exited != 0) {
            printErr("error: git pull failed\n");
            return error.Explained;
        }
    } else {
        const clone_args: []const []const u8 = &.{ "git", "clone", git_url, ext_dir };
        var clone = std.process.Child.init(clone_args, allocator);
        clone.stderr_behavior = .Inherit;
        clone.stdout_behavior = .Inherit;
        try clone.spawn();
        const clone_term = try clone.wait();
        if (clone_term.Exited != 0) {
            printErr("error: git clone failed\n");
            return error.Explained;
        }
    }

    // Read manifest
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/cog-extension.json", .{ext_dir});
    defer allocator.free(manifest_path);

    const manifest = readManifest(allocator, manifest_path) catch {
        printErr("error: no valid cog-extension.json found in repository\n");
        return error.Explained;
    };
    defer freeManifest(allocator, &manifest);

    // Run build command
    const build_args: []const []const u8 = &.{ "/bin/sh", "-c", manifest.build_cmd };
    var build = std.process.Child.init(build_args, allocator);
    build.stderr_behavior = .Inherit;
    build.stdout_behavior = .Inherit;
    build.cwd = ext_dir;
    try build.spawn();
    const build_term = try build.wait();
    if (build_term.Exited != 0) {
        printErr("error: build command failed\n");
        return error.Explained;
    }

    // Verify binary exists
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ ext_dir, manifest.name });
    defer allocator.free(bin_path);

    const bin_exists = blk: {
        const f = std.fs.openFileAbsolute(bin_path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    if (!bin_exists) {
        printErr("error: build did not produce binary at bin/");
        printErr(manifest.name);
        printErr("\n");
        return error.Explained;
    }

    // Output JSON
    const json_mod = std.json;
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: json_mod.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("name");
    try s.write(manifest.name);
    try s.objectField("installed");
    try s.write(true);
    try s.objectField("path");
    try s.write(ext_dir);
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "resolveByExtension finds built-in for .go" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".go");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("scip-go", ext.?.name);
    try std.testing.expect(!ext.?.installed);
}

test "resolveByExtension finds built-in for .ts" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".ts");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("scip-typescript", ext.?.name);
}

test "resolveByExtension finds built-in for .py" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".py");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("scip-python", ext.?.name);
}

test "resolveByExtension finds built-in for .java" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".java");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("scip-java", ext.?.name);
}

test "resolveByExtension finds built-in for .rs" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".rs");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("rust-analyzer", ext.?.name);
}

test "resolveByExtension returns null for unknown" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".unknown");
    try std.testing.expect(ext == null);
}

// ── Debugger Config Tests ───────────────────────────────────────────────

test "built-in Python extension has debugpy debugger config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".py");
    try std.testing.expect(ext != null);
    const dbg = ext.?.debugger orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(DebuggerType.dap, dbg.debugger_type);
    const adapter = dbg.adapter orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("python3", adapter.command);
    try std.testing.expectEqualStrings("tcp", adapter.transport);
}

test "built-in Go extension has delve debugger config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".go");
    try std.testing.expect(ext != null);
    const dbg = ext.?.debugger orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(DebuggerType.dap, dbg.debugger_type);
    const adapter = dbg.adapter orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("dlv", adapter.command);
    try std.testing.expectEqualStrings("tcp", adapter.transport);
    try std.testing.expect(dbg.boundary_markers.len > 0);
}

test "built-in Rust extension has native debugger config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".rs");
    try std.testing.expect(ext != null);
    const dbg = ext.?.debugger orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(DebuggerType.native, dbg.debugger_type);
    try std.testing.expect(dbg.adapter == null);
}

test "resolveByExtension returns null debugger for unknown extension" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".unknown");
    try std.testing.expect(ext == null);
}

test "Extension without debugger field defaults to null" {
    // All built-in extensions have debugger now, but the struct default is null
    const ext = Extension{
        .name = "test",
        .file_extensions = &.{".test"},
        .command = "test-cmd",
        .args = &.{},
        .installed = false,
        .path = "",
    };
    try std.testing.expect(ext.debugger == null);
}

test "parseManifest reads debugger config with type dap" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"name":"test-ext","extensions":[".test"],"args":["{file}"],"build":"make",
        \\"debugger":{"type":"dap","adapter":{"command":"debugpy","args":["--listen",":{port}"],"transport":"tcp"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = (try parseDebuggerConfig(allocator, obj)) orelse return error.TestUnexpectedResult;
    defer {
        if (dbg.adapter_command) |c| allocator.free(c);
        if (dbg.adapter_transport) |t| allocator.free(t);
        if (dbg.adapter_args) |args| {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }
    }

    try std.testing.expectEqual(DebuggerType.dap, dbg.debugger_type);
    try std.testing.expectEqualStrings("debugpy", dbg.adapter_command.?);
    try std.testing.expectEqualStrings("tcp", dbg.adapter_transport.?);
    try std.testing.expect(dbg.adapter_args != null);
    try std.testing.expectEqual(@as(usize, 2), dbg.adapter_args.?.len);
}

test "parseManifest reads debugger config with type native" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"name":"zig-lang","extensions":[".zig"],"args":[],"build":"zig build",
        \\"debugger":{"type":"native"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = (try parseDebuggerConfig(allocator, obj)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(DebuggerType.native, dbg.debugger_type);
    try std.testing.expect(dbg.adapter_command == null);
}

test "parseManifest reads boundary_markers array" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"name":"go-ext","extensions":[".go"],"args":[],"build":"make",
        \\"debugger":{"type":"dap","boundary_markers":["crosscall2","_cgo_topofstack"]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = (try parseDebuggerConfig(allocator, obj)) orelse return error.TestUnexpectedResult;
    defer {
        for (dbg.boundary_markers) |m| allocator.free(m);
        allocator.free(dbg.boundary_markers);
    }

    try std.testing.expectEqual(@as(usize, 2), dbg.boundary_markers.len);
    try std.testing.expectEqualStrings("crosscall2", dbg.boundary_markers[0]);
    try std.testing.expectEqualStrings("_cgo_topofstack", dbg.boundary_markers[1]);
}

test "parseManifest reads adapter command and args" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"name":"test","extensions":[],"args":[],"build":"",
        \\"debugger":{"type":"dap","adapter":{"command":"dlv","args":["dap","--listen",":{port}"],"transport":"tcp"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = (try parseDebuggerConfig(allocator, obj)) orelse return error.TestUnexpectedResult;
    defer {
        if (dbg.adapter_command) |c| allocator.free(c);
        if (dbg.adapter_transport) |t| allocator.free(t);
        if (dbg.adapter_args) |args| {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }
    }

    try std.testing.expectEqualStrings("dlv", dbg.adapter_command.?);
    try std.testing.expectEqual(@as(usize, 3), dbg.adapter_args.?.len);
    try std.testing.expectEqualStrings("dap", dbg.adapter_args.?[0]);
    try std.testing.expectEqualStrings("--listen", dbg.adapter_args.?[1]);
    try std.testing.expectEqualStrings(":{port}", dbg.adapter_args.?[2]);
}

test "parseManifest without debugger field returns null debugger" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"name":"simple","extensions":[".txt"],"args":[],"build":"make"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = try parseDebuggerConfig(allocator, obj);
    try std.testing.expect(dbg == null);
}

test "parseManifest preserves backward compat with indexer-only manifest" {
    const allocator = std.testing.allocator;
    // Manifest with no "debugger" key at all — standard indexer-only
    const json_str =
        \\{"name":"scip-ruby","extensions":[".rb"],"args":["{file}","--output","{output}"],"build":"make"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = try parseDebuggerConfig(allocator, obj);
    try std.testing.expect(dbg == null);
}

test "resolveByExtension returns debugger config for .py" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".py");
    try std.testing.expect(ext != null);
    const dbg = ext.?.debugger orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(DebuggerType.dap, dbg.debugger_type);
    try std.testing.expect(dbg.adapter != null);
    try std.testing.expectEqualStrings("python3", dbg.adapter.?.command);
}
