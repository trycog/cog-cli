const std = @import("std");
const paths = @import("paths.zig");

// ANSI styles
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Debug Config Types ──────────────────────────────────────────────────

pub const DebuggerType = enum { native, dap };
pub const TransportType = enum { stdio, tcp };
pub const RestartMethod = enum { native, respawn };
pub const AdapterInstallMethod = enum { system, github_release, compile_embedded };

pub const DependencyCheck = struct {
    command: []const u8,
    check_args: []const []const u8,
    error_message: []const u8,
};

pub const AdapterInstall = struct {
    method: AdapterInstallMethod,
    repo: ?[]const u8 = null,
    version: ?[]const u8 = null,
    asset_pattern: ?[]const u8 = null,
    extract_format: ?[]const u8 = null,
    install_dir: []const u8,
    entry_point: []const u8,
};

pub const ChildSessionConfig = struct {
    enabled: bool = false,
    stop_on_entry_workaround: bool = false,
};

pub const DapConfig = struct {
    adapter_command: []const u8,
    adapter_args: []const []const u8,
    transport: TransportType = .stdio,
    port_stdout_prefix: ?[]const u8 = null,
    port_detection_timeout_ms: u32 = 10_000,
    adapter_id: []const u8 = "cog",
    supports_start_debugging: bool = false,
    launch_extra_args_json: ?[]const u8 = null,
    launch_args_template: ?[]const u8 = null,
    child_sessions: ChildSessionConfig = .{},
    restart_method: RestartMethod = .native,
    boundary_markers: []const []const u8 = &.{},
    dependencies: []const DependencyCheck = &.{},
    adapter_install: ?AdapterInstall = null,
};

pub const NativeConfig = struct {
    boundary_markers: []const []const u8 = &.{},
};

pub const DebugConfig = union(DebuggerType) {
    native: NativeConfig,
    dap: DapConfig,
};

// ── Indexing Config Types ───────────────────────────────────────────────

pub const IndexerType = enum { tree_sitter, scip_binary };

pub const TreeSitterConfig = struct {
    grammar_name: []const u8,
    query_source: []const u8,
    scip_name: []const u8,
};

pub const ScipBinaryConfig = struct {
    command: []const u8,
    args: []const []const u8,
};

pub const IndexerConfig = union(IndexerType) {
    tree_sitter: TreeSitterConfig,
    scip_binary: ScipBinaryConfig,
};

// ── Extension ───────────────────────────────────────────────────────────

/// An extension definition (either built-in or installed).
pub const Extension = struct {
    name: []const u8,
    file_extensions: []const []const u8,
    language_names: []const []const u8 = &.{},
    /// Primary indexer: tree-sitter for builtins, scip_binary for installed extensions.
    indexer: ?IndexerConfig = null,
    /// Optional secondary SCIP indexer (external tool) for richer type info.
    scip_indexer: ?ScipBinaryConfig = null,
    /// Debug configuration. Null if extension does not support debugging.
    debug: ?DebugConfig = null,
    /// Whether this is an installed (non-built-in) extension.
    installed: bool = false,
    /// For installed extensions: absolute path to the extension directory.
    path: []const u8 = "",
    /// Build command for installed extensions.
    build: []const u8 = "",
};

// ── Shared Debug Configs ────────────────────────────────────────────────

const js_dap_config: DapConfig = .{
    .adapter_command = "node",
    .adapter_args = &.{ "{entry_point}", "0", "127.0.0.1" },
    .transport = .tcp,
    .port_stdout_prefix = "Debug server listening at ",
    .adapter_id = "pwa-node",
    .supports_start_debugging = true,
    .launch_extra_args_json =
    \\{"type":"pwa-node","console":"internalConsole","sourceMaps":true,"__workspaceFolder":"{cwd}","outFiles":["{cwd}/**/*.js","!**/node_modules/**"],"resolveSourceMapLocations":["**","!**/node_modules/**"]}
    ,
    .child_sessions = .{ .enabled = true, .stop_on_entry_workaround = true },
    .restart_method = .respawn,
    .dependencies = &.{
        .{ .command = "node", .check_args = &.{"--version"}, .error_message = "node not found on PATH" },
    },
    .adapter_install = .{
        .method = .github_release,
        .repo = "microsoft/vscode-js-debug",
        .version = "v1.105.0",
        .asset_pattern = "js-debug-dap-v1.105.0.tar.gz",
        .extract_format = "tar.gz",
        .install_dir = "js-debug",
        .entry_point = "js-debug/src/dapDebugServer.js",
    },
};

const js_scip_config: ScipBinaryConfig = .{
    .command = "scip-typescript",
    .args = &.{ "index", "--infer-tsconfig", "{file}", "--output", "{output}" },
};

// ── Builtins ────────────────────────────────────────────────────────────

/// Built-in extension definitions compiled into the binary.
/// Every bundled language gets a single entry with all its capabilities.
pub const builtins = [_]Extension{
    // Go
    .{
        .name = "go",
        .file_extensions = &.{".go"},
        .language_names = &.{"go"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "go",
            .query_source = @embedFile("queries/go.scm"),
            .scip_name = "go",
        } },
        .scip_indexer = .{ .command = "scip-go", .args = &.{ "{file}", "--output", "{output}" } },
        .debug = .{ .dap = .{
            .adapter_command = "dlv",
            .adapter_args = &.{"dap"},
            .transport = .stdio,
            .boundary_markers = &.{ "_cgo_topofstack", "crosscall2" },
            .dependencies = &.{
                .{ .command = "dlv", .check_args = &.{"version"}, .error_message = "dlv (Delve) not found on PATH" },
            },
        } },
    },
    // JavaScript
    .{
        .name = "javascript",
        .file_extensions = &.{ ".js", ".jsx", ".mjs", ".cjs" },
        .language_names = &.{"javascript"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "javascript",
            .query_source = @embedFile("queries/javascript.scm"),
            .scip_name = "javascript",
        } },
        .scip_indexer = js_scip_config,
        .debug = .{ .dap = js_dap_config },
    },
    // TypeScript
    .{
        .name = "typescript",
        .file_extensions = &.{ ".ts", ".mts" },
        .language_names = &.{"typescript"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "typescript",
            .query_source = @embedFile("queries/typescript.scm"),
            .scip_name = "typescript",
        } },
        .scip_indexer = js_scip_config,
        .debug = .{ .dap = js_dap_config },
    },
    // TSX
    .{
        .name = "tsx",
        .file_extensions = &.{".tsx"},
        .language_names = &.{"tsx"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "tsx",
            .query_source = @embedFile("queries/tsx.scm"),
            .scip_name = "tsx",
        } },
        .scip_indexer = js_scip_config,
        .debug = .{ .dap = js_dap_config },
    },
    // Python
    .{
        .name = "python",
        .file_extensions = &.{ ".py", ".pyi" },
        .language_names = &.{"python"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "python",
            .query_source = @embedFile("queries/python.scm"),
            .scip_name = "python",
        } },
        .scip_indexer = .{ .command = "scip-python", .args = &.{ "index", "{file}", "--output", "{output}" } },
        .debug = .{ .dap = .{
            .adapter_command = "python3",
            .adapter_args = &.{ "-m", "debugpy.adapter" },
            .transport = .stdio,
            .dependencies = &.{
                .{ .command = "python3", .check_args = &.{ "-c", "import debugpy" }, .error_message = "debugpy not available. Ensure python3 and debugpy are installed (pip install debugpy)" },
            },
        } },
    },
    // Java
    .{
        .name = "java",
        .file_extensions = &.{".java"},
        .language_names = &.{"java"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "java",
            .query_source = @embedFile("queries/java.scm"),
            .scip_name = "java",
        } },
        .scip_indexer = .{ .command = "scip-java", .args = &.{ "{file}", "--output", "{output}" } },
        .debug = .{ .dap = .{
            .adapter_command = "java",
            .adapter_args = &.{ "-cp", "{adapter_path}", "JdiDapServer" },
            .transport = .stdio,
            .dependencies = &.{
                .{ .command = "java", .check_args = &.{"-version"}, .error_message = "java not found on PATH" },
                .{ .command = "javac", .check_args = &.{"-version"}, .error_message = "javac not found on PATH" },
            },
            .adapter_install = .{
                .method = .compile_embedded,
                .install_dir = "jdi-dap",
                .entry_point = "jdi-dap/JdiDapServer.class",
            },
        } },
    },
    // Rust
    .{
        .name = "rust",
        .file_extensions = &.{".rs"},
        .language_names = &.{"rust"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "rust",
            .query_source = @embedFile("queries/rust.scm"),
            .scip_name = "rust",
        } },
        .scip_indexer = .{ .command = "rust-analyzer", .args = &.{ "scip", "{file}", "{output}" } },
        .debug = .{ .native = .{} },
    },
    // C
    .{
        .name = "c",
        .file_extensions = &.{ ".c", ".h" },
        .language_names = &.{"c"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "c",
            .query_source = @embedFile("queries/c.scm"),
            .scip_name = "c",
        } },
        .debug = .{ .native = .{} },
    },
    // C++
    .{
        .name = "cpp",
        .file_extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hxx", ".hh" },
        .language_names = &.{ "cpp", "c++" },
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "cpp",
            .query_source = @embedFile("queries/cpp.scm"),
            .scip_name = "cpp",
        } },
        .debug = .{ .native = .{} },
    },
};

// ── Public API ──────────────────────────────────────────────────────────

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

/// Resolve a language hint (e.g. "python", "go") to the best matching Extension.
/// Installed extensions override built-ins when they share language names.
pub fn resolveByLanguageHint(allocator: std.mem.Allocator, lang: []const u8) ?Extension {
    if (scanInstalledByLanguageHint(allocator, lang)) |ext| return ext;
    for (&builtins) |*b| {
        for (b.language_names) |name| {
            if (std.mem.eql(u8, name, lang)) return b.*;
        }
    }
    return null;
}

/// Check if a file extension is supported by any built-in extension.
/// Cheap comptime-array scan — no heap allocation, no disk I/O.
pub fn isBuiltinSupported(file_ext: []const u8) bool {
    for (&builtins) |*b| {
        for (b.file_extensions) |ext| {
            if (std.mem.eql(u8, ext, file_ext)) return true;
        }
    }
    return false;
}

/// Info about an installed extension for display purposes.
pub const InstalledInfo = struct {
    name: []const u8,
    file_extensions: []const []const u8,
    has_debugger: bool,
};

/// List all installed extensions found in ~/.config/cog/extensions/.
/// Caller must free each entry's name and file_extensions with freeInstalledList().
pub fn listInstalled(allocator: std.mem.Allocator) ![]InstalledInfo {
    var result: std.ArrayListUnmanaged(InstalledInfo) = .empty;
    errdefer {
        for (result.items) |item| {
            allocator.free(item.name);
            for (item.file_extensions) |e| allocator.free(e);
            allocator.free(item.file_extensions);
        }
        result.deinit(allocator);
    }

    const config_dir = try paths.getGlobalConfigDir(allocator);
    defer allocator.free(config_dir);

    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/extensions", .{config_dir});
    defer allocator.free(ext_dir);

    var dir = std.fs.openDirAbsolute(ext_dir, .{ .iterate = true }) catch return try result.toOwnedSlice(allocator);
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}/cog-extension.json", .{ ext_dir, entry.name });
        defer allocator.free(manifest_path);

        const manifest = readManifest(allocator, manifest_path) catch continue;
        defer {
            for (manifest.args) |a| allocator.free(a);
            allocator.free(manifest.args);
            allocator.free(manifest.build_cmd);
            allocator.free(manifest.ext_dir);
            freeDebuggerAllocs(allocator, manifest.debugger);
        }
        // Keep name and file_extensions, free the rest
        try result.append(allocator, .{
            .name = manifest.name,
            .file_extensions = manifest.file_extensions,
            .has_debugger = manifest.debugger != null,
        });
    }

    return try result.toOwnedSlice(allocator);
}

/// Free the list returned by listInstalled.
pub fn freeInstalledList(allocator: std.mem.Allocator, list: []InstalledInfo) void {
    for (list) |item| {
        allocator.free(item.name);
        for (item.file_extensions) |e| allocator.free(e);
        allocator.free(item.file_extensions);
    }
    allocator.free(list);
}

// ── Internal: Installed Extension Scanning ──────────────────────────────

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

        const manifest_path = std.fmt.allocPrint(allocator, "{s}/{s}/cog-extension.json", .{ ext_dir, entry.name }) catch continue;
        defer allocator.free(manifest_path);

        const manifest = readManifest(allocator, manifest_path) catch continue;

        // Check if this extension handles the given file extension
        for (manifest.file_extensions) |ext| {
            if (std.mem.eql(u8, ext, file_ext)) {
                const bin_path = std.fmt.allocPrint(allocator, "{s}/{s}/bin/{s}", .{ ext_dir, entry.name, manifest.name }) catch continue;

                const result_ext = manifestToExtension(manifest, bin_path);
                return result_ext;
            }
        }

        // Not a match — free the manifest allocations
        freeManifest(allocator, &manifest);
    }

    return null;
}

/// Scan installed extensions for one matching the given language hint.
fn scanInstalledByLanguageHint(allocator: std.mem.Allocator, lang: []const u8) ?Extension {
    const config_dir = paths.getGlobalConfigDir(allocator) catch return null;
    defer allocator.free(config_dir);

    const ext_dir = std.fmt.allocPrint(allocator, "{s}/extensions", .{config_dir}) catch return null;
    defer allocator.free(ext_dir);

    var dir = std.fs.openDirAbsolute(ext_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return null) |entry| {
        if (entry.kind != .directory) continue;

        const manifest_path = std.fmt.allocPrint(allocator, "{s}/{s}/cog-extension.json", .{ ext_dir, entry.name }) catch continue;
        defer allocator.free(manifest_path);

        const manifest = readManifest(allocator, manifest_path) catch continue;

        // Check if this extension handles the given language name
        for (manifest.language_names) |name| {
            if (std.mem.eql(u8, name, lang)) {
                const bin_path = std.fmt.allocPrint(allocator, "{s}/{s}/bin/{s}", .{ ext_dir, entry.name, manifest.name }) catch continue;

                const result_ext = manifestToExtension(manifest, bin_path);
                return result_ext;
            }
        }

        freeManifest(allocator, &manifest);
    }

    return null;
}

/// Convert a parsed ManifestData into an Extension struct.
fn manifestToExtension(manifest: ManifestData, bin_path: []const u8) Extension {
    return Extension{
        .name = manifest.name,
        .file_extensions = manifest.file_extensions,
        .language_names = manifest.language_names,
        .indexer = .{ .scip_binary = .{
            .command = bin_path,
            .args = manifest.args,
        } },
        .debug = if (manifest.debugger) |d| d.toDebugConfig() else null,
        .installed = true,
        .path = manifest.ext_dir,
        .build = manifest.build_cmd,
    };
}

// ── Internal: Manifest Parsing ──────────────────────────────────────────

const ManifestData = struct {
    name: []const u8,
    file_extensions: []const []const u8,
    language_names: []const []const u8,
    args: []const []const u8,
    build_cmd: []const u8,
    ext_dir: []const u8,
    debugger: ?AllocatedDebuggerConfig = null,
};

/// Heap-allocated version of debug config for installed extensions.
const AllocatedDebuggerConfig = struct {
    debugger_type: DebuggerType,
    adapter_command: ?[]const u8 = null,
    adapter_args: ?[]const []const u8 = null,
    adapter_transport: ?[]const u8 = null,
    launch_args_template: ?[]const u8 = null,
    boundary_markers: []const []const u8 = &.{},

    fn toDebugConfig(self: *const AllocatedDebuggerConfig) DebugConfig {
        return switch (self.debugger_type) {
            .native => .{ .native = .{
                .boundary_markers = self.boundary_markers,
            } },
            .dap => .{ .dap = .{
                .adapter_command = self.adapter_command orelse "",
                .adapter_args = self.adapter_args orelse &.{},
                .transport = if (self.adapter_transport) |t|
                    if (std.mem.eql(u8, t, "tcp")) .tcp else .stdio
                else
                    .stdio,
                .launch_args_template = self.launch_args_template,
                .boundary_markers = self.boundary_markers,
            } },
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

    // Check manifest version. Version 1 (default) uses the legacy format.
    // Version 2 manifests may use new fields (indexing, debugging sections)
    // but we parse them through the same v1 path for backward compatibility.
    // TODO: Add dedicated v2 parsing for richer indexing/debugging config
    // when external extensions need capabilities beyond SCIP binary + basic DAP.
    _ = if (obj.get("version")) |v| (if (v == .integer) v.integer else @as(i64, 1)) else @as(i64, 1);

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

    // Parse optional language_names array
    const language_names = if (obj.get("language_names")) |ln_val| blk: {
        if (ln_val != .array) break :blk @as([]const []const u8, &.{});
        const names = allocator.alloc([]const u8, ln_val.array.items.len) catch break :blk @as([]const []const u8, &.{});
        var ni: usize = 0;
        for (ln_val.array.items) |item| {
            if (item == .string) {
                names[ni] = allocator.dupe(u8, item.string) catch continue;
                ni += 1;
            }
        }
        break :blk @as([]const []const u8, names[0..ni]);
    } else @as([]const []const u8, &.{});

    // Parse optional debugger config
    const debugger_config = parseDebuggerConfig(allocator, obj) catch null;

    return .{
        .name = name,
        .file_extensions = file_extensions,
        .language_names = language_names,
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
            // Ensure transport is always heap-allocated when command is set
            if (result.adapter_command != null and result.adapter_transport == null) {
                result.adapter_transport = try allocator.dupe(u8, "stdio");
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

// ── Memory Management ───────────────────────────────────────────────────

fn freeManifest(allocator: std.mem.Allocator, manifest: *const ManifestData) void {
    allocator.free(manifest.name);
    for (manifest.file_extensions) |e| allocator.free(e);
    allocator.free(manifest.file_extensions);
    for (manifest.language_names) |n| allocator.free(n);
    if (manifest.language_names.len > 0) allocator.free(manifest.language_names);
    for (manifest.args) |a| allocator.free(a);
    allocator.free(manifest.args);
    allocator.free(manifest.build_cmd);
    allocator.free(manifest.ext_dir);
    freeDebuggerAllocs(allocator, manifest.debugger);
}

/// Free heap-allocated fields of an Extension that originated from an
/// installed extension (where all strings are heap-allocated). Built-in
/// extensions use comptime literals and must NOT be freed — the `installed`
/// flag on Extension guards this.
pub fn freeExtension(allocator: std.mem.Allocator, ext: *const Extension) void {
    if (!ext.installed) return;

    allocator.free(ext.name);
    for (ext.file_extensions) |e| allocator.free(e);
    allocator.free(ext.file_extensions);
    for (ext.language_names) |n| allocator.free(n);
    if (ext.language_names.len > 0) allocator.free(ext.language_names);
    // Free indexer config (scip_binary command/args from installed extensions)
    if (ext.indexer) |idx| {
        switch (idx) {
            .scip_binary => |sb| {
                allocator.free(sb.command);
                for (sb.args) |a| allocator.free(a);
                if (sb.args.len > 0) allocator.free(sb.args);
            },
            .tree_sitter => {}, // tree-sitter configs are comptime
        }
    }
    allocator.free(ext.path);
    if (ext.build.len > 0) allocator.free(ext.build);
    // Free debug config
    if (ext.debug) |dc| {
        switch (dc) {
            .dap => |dap| {
                allocator.free(dap.adapter_command);
                for (dap.adapter_args) |a| allocator.free(a);
                if (dap.adapter_args.len > 0) allocator.free(dap.adapter_args);
                if (dap.launch_args_template) |l| allocator.free(l);
                for (dap.boundary_markers) |m| allocator.free(m);
                if (dap.boundary_markers.len > 0) allocator.free(dap.boundary_markers);
            },
            .native => |nat| {
                for (nat.boundary_markers) |m| allocator.free(m);
                if (nat.boundary_markers.len > 0) allocator.free(nat.boundary_markers);
            },
        }
    }
}

fn freeDebuggerAllocs(allocator: std.mem.Allocator, debugger: ?AllocatedDebuggerConfig) void {
    const dbg = debugger orelse return;
    if (dbg.adapter_command) |c_val| allocator.free(c_val);
    if (dbg.adapter_transport) |t| allocator.free(t);
    if (dbg.adapter_args) |args| {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    if (dbg.launch_args_template) |l| allocator.free(l);
    for (dbg.boundary_markers) |m| allocator.free(m);
    if (dbg.boundary_markers.len > 0) allocator.free(dbg.boundary_markers);
}

// ── Utility ─────────────────────────────────────────────────────────────

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

// ── Extension Install ───────────────────────────────────────────────────

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
    var build_proc = std.process.Child.init(build_args, allocator);
    build_proc.stderr_behavior = .Inherit;
    build_proc.stdout_behavior = .Inherit;
    build_proc.cwd = ext_dir;
    try build_proc.spawn();
    const build_term = try build_proc.wait();
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
    try std.testing.expectEqualStrings("go", ext.?.name);
    try std.testing.expect(!ext.?.installed);
}

test "resolveByExtension finds built-in for .ts" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".ts");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("typescript", ext.?.name);
}

test "resolveByExtension finds built-in for .py" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".py");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("python", ext.?.name);
}

test "resolveByExtension finds built-in for .java" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".java");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("java", ext.?.name);
}

test "resolveByExtension finds built-in for .rs" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".rs");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("rust", ext.?.name);
}

test "resolveByExtension finds built-in for .c" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".c");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("c", ext.?.name);
}

test "resolveByExtension finds built-in for .cpp" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".cpp");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("cpp", ext.?.name);
}

test "resolveByExtension finds built-in for .jsx" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".jsx");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("javascript", ext.?.name);
}

test "resolveByExtension finds built-in for .tsx" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".tsx");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("tsx", ext.?.name);
}

test "resolveByExtension returns null for unknown" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".unknown");
    try std.testing.expect(ext == null);
}

// ── Debug Config Tests ──────────────────────────────────────────────────

test "built-in Python extension has debugpy debug config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".py");
    try std.testing.expect(ext != null);
    const dc = ext.?.debug orelse return error.TestUnexpectedResult;
    try std.testing.expect(dc == .dap);
    const dap = dc.dap;
    try std.testing.expectEqualStrings("python3", dap.adapter_command);
    try std.testing.expectEqual(TransportType.stdio, dap.transport);
}

test "built-in Go extension has delve debug config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".go");
    try std.testing.expect(ext != null);
    const dc = ext.?.debug orelse return error.TestUnexpectedResult;
    try std.testing.expect(dc == .dap);
    const dap = dc.dap;
    try std.testing.expectEqualStrings("dlv", dap.adapter_command);
    try std.testing.expectEqual(TransportType.stdio, dap.transport);
    try std.testing.expect(dap.boundary_markers.len > 0);
}

test "built-in Rust extension has native debug config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".rs");
    try std.testing.expect(ext != null);
    const dc = ext.?.debug orelse return error.TestUnexpectedResult;
    try std.testing.expect(dc == .native);
}

test "built-in JavaScript extension has vscode-js-debug config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".js");
    try std.testing.expect(ext != null);
    const dc = ext.?.debug orelse return error.TestUnexpectedResult;
    const dap = dc.dap;
    try std.testing.expectEqualStrings("node", dap.adapter_command);
    try std.testing.expectEqual(TransportType.tcp, dap.transport);
    try std.testing.expectEqualStrings("pwa-node", dap.adapter_id);
    try std.testing.expect(dap.supports_start_debugging);
    try std.testing.expect(dap.child_sessions.enabled);
    try std.testing.expectEqual(RestartMethod.respawn, dap.restart_method);
    try std.testing.expect(dap.adapter_install != null);
}

test "built-in Java extension has JDI debug config" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".java");
    try std.testing.expect(ext != null);
    const dc = ext.?.debug orelse return error.TestUnexpectedResult;
    const dap = dc.dap;
    try std.testing.expectEqualStrings("java", dap.adapter_command);
    try std.testing.expectEqual(TransportType.stdio, dap.transport);
    try std.testing.expect(dap.adapter_install != null);
    try std.testing.expectEqual(AdapterInstallMethod.compile_embedded, dap.adapter_install.?.method);
}

test "resolveByExtension returns null debug for unknown extension" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".unknown");
    try std.testing.expect(ext == null);
}

test "Extension without debug field defaults to null" {
    const ext = Extension{
        .name = "test",
        .file_extensions = &.{".test"},
    };
    try std.testing.expect(ext.debug == null);
}

// ── Indexer Config Tests ────────────────────────────────────────────────

test "built-in Go has tree-sitter indexer" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".go");
    try std.testing.expect(ext != null);
    const idx = ext.?.indexer orelse return error.TestUnexpectedResult;
    try std.testing.expect(idx == .tree_sitter);
    try std.testing.expectEqualStrings("go", idx.tree_sitter.grammar_name);
    try std.testing.expectEqualStrings("go", idx.tree_sitter.scip_name);
}

test "built-in Go has scip_indexer" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".go");
    try std.testing.expect(ext != null);
    const si = ext.?.scip_indexer orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("scip-go", si.command);
}

test "built-in C has tree-sitter indexer but no scip_indexer" {
    const allocator = std.testing.allocator;
    const ext = resolveByExtension(allocator, ".c");
    try std.testing.expect(ext != null);
    try std.testing.expect(ext.?.indexer != null);
    try std.testing.expect(ext.?.scip_indexer == null);
}

// ── Language Hint Tests ─────────────────────────────────────────────────

test "resolveByLanguageHint finds go" {
    const allocator = std.testing.allocator;
    const ext = resolveByLanguageHint(allocator, "go");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("go", ext.?.name);
}

test "resolveByLanguageHint finds python" {
    const allocator = std.testing.allocator;
    const ext = resolveByLanguageHint(allocator, "python");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("python", ext.?.name);
}

test "resolveByLanguageHint finds javascript" {
    const allocator = std.testing.allocator;
    const ext = resolveByLanguageHint(allocator, "javascript");
    try std.testing.expect(ext != null);
    try std.testing.expectEqualStrings("javascript", ext.?.name);
}

test "resolveByLanguageHint returns null for unknown" {
    const allocator = std.testing.allocator;
    const ext = resolveByLanguageHint(allocator, "brainfuck");
    try std.testing.expect(ext == null);
}

// ── isBuiltinSupported Tests ────────────────────────────────────────────

test "isBuiltinSupported returns true for known extensions" {
    try std.testing.expect(isBuiltinSupported(".go"));
    try std.testing.expect(isBuiltinSupported(".py"));
    try std.testing.expect(isBuiltinSupported(".js"));
    try std.testing.expect(isBuiltinSupported(".ts"));
    try std.testing.expect(isBuiltinSupported(".java"));
    try std.testing.expect(isBuiltinSupported(".rs"));
    try std.testing.expect(isBuiltinSupported(".c"));
    try std.testing.expect(isBuiltinSupported(".h"));
    try std.testing.expect(isBuiltinSupported(".cpp"));
}

test "isBuiltinSupported returns false for unknown extensions" {
    try std.testing.expect(!isBuiltinSupported(".zig"));
    try std.testing.expect(!isBuiltinSupported(".rb"));
    try std.testing.expect(!isBuiltinSupported(""));
}

// ── Manifest Parsing Tests ──────────────────────────────────────────────

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
        if (dbg.adapter_command) |c_val| allocator.free(c_val);
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
        if (dbg.adapter_command) |c_val| allocator.free(c_val);
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
    const json_str =
        \\{"name":"scip-ruby","extensions":[".rb"],"args":["{file}","--output","{output}"],"build":"make"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const dbg = try parseDebuggerConfig(allocator, obj);
    try std.testing.expect(dbg == null);
}
