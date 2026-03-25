const std = @import("std");
const curl = @import("curl.zig");
const paths = @import("paths.zig");
const debug_log = @import("debug_log.zig");

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
    /// Override the JSON field name for the program value in the DAP launch request.
    /// Default "program". Set to e.g. "task" for ElixirLS mix_task mode.
    program_field: []const u8 = "program",
    /// Override the JSON field name for the args array in the DAP launch request.
    /// Default "args". Set to e.g. "taskArgs" for ElixirLS mix_task mode.
    args_field: []const u8 = "args",
    /// When true, args[0] is used as the program field value instead of the
    /// program parameter, and args[1:] are sent as the args array. Used for
    /// mix-task style launchers where the user passes program="mix"
    /// args=["run", "-e", "..."] and the adapter expects task="run".
    args_first_is_program: bool = false,
    /// When true, the proxy will NOT force stopOnEntry=true in the launch
    /// request and will NOT try to consume an entry-stop event.  Use this
    /// for adapters that ignore stopOnEntry (e.g. ElixirLS) — forcing it
    /// causes the proxy to consume the first real breakpoint hit as a
    /// phantom "entry stop" and auto-continue past it.
    skip_entry_stop: bool = false,
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
    /// Query capture contract for architecture-aware exploration (all optional):
    /// - @reference.import for module/file imports
    /// - @reference.call for function/method calls
    /// - standard definition captures plus enclosing ranges enable containment
    query_source: []const u8,
    scip_name: []const u8,
};

pub const ArchitectureCapabilities = struct {
    imports: bool = false,
    calls: bool = false,
    containment: bool = false,
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
    /// Architecture relationship coverage available from this extension.
    architecture: ArchitectureCapabilities = .{},
    /// Debug configuration. Null if extension does not support debugging.
    debug: ?DebugConfig = null,
    /// Whether this is an installed (non-built-in) extension.
    installed: bool = false,
    /// For installed extensions: absolute path to the extension directory.
    path: []const u8 = "",
    /// Build command for installed extensions.
    build: []const u8 = "",
};

fn querySourceHasCapture(query_source: []const u8, capture: []const u8) bool {
    return std.mem.indexOf(u8, query_source, capture) != null;
}

pub fn validateArchitectureCapabilities(ext: Extension) bool {
    if (!ext.architecture.imports and !ext.architecture.calls and !ext.architecture.containment) return true;
    const indexer = ext.indexer orelse return false;
    return switch (indexer) {
        .tree_sitter => |ts| blk: {
            if (ext.architecture.imports and !querySourceHasCapture(ts.query_source, "@reference.import")) break :blk false;
            if (ext.architecture.calls and !querySourceHasCapture(ts.query_source, "@reference.call")) break :blk false;
            if (ext.architecture.containment and std.mem.indexOf(u8, ts.query_source, "@definition.") == null) break :blk false;
            break :blk true;
        },
        .scip_binary => true,
    };
}

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
        .architecture = .{ .imports = true, .calls = true, .containment = true },
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
        .architecture = .{ .imports = true, .calls = true, .containment = true },
        .debug = .{ .dap = js_dap_config },
    },
    // MDX
    .{
        .name = "mdx",
        .file_extensions = &.{".mdx"},
        .language_names = &.{"mdx"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "mdx",
            .query_source = @embedFile("queries/mdx.scm"),
            .scip_name = "mdx",
        } },
    },
    // Markdown
    .{
        .name = "markdown",
        .file_extensions = &.{ ".md", ".markdown" },
        .language_names = &.{"markdown"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "markdown",
            .query_source = @embedFile("queries/markdown.scm"),
            .scip_name = "markdown",
        } },
    },
    // YAML
    .{
        .name = "yaml",
        .file_extensions = &.{ ".yaml", ".yml" },
        .language_names = &.{"yaml"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "yaml",
            .query_source = @embedFile("queries/yaml.scm"),
            .scip_name = "yaml",
        } },
    },
    // TOML
    .{
        .name = "toml",
        .file_extensions = &.{".toml"},
        .language_names = &.{"toml"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "toml",
            .query_source = @embedFile("queries/toml.scm"),
            .scip_name = "toml",
        } },
    },
    // reStructuredText
    .{
        .name = "rst",
        .file_extensions = &.{".rst"},
        .language_names = &.{"rst"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "rst",
            .query_source = @embedFile("queries/rst.scm"),
            .scip_name = "rst",
        } },
    },
    // AsciiDoc
    .{
        .name = "asciidoc",
        .file_extensions = &.{ ".adoc", ".asciidoc" },
        .language_names = &.{"asciidoc"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "asciidoc",
            .query_source = @embedFile("queries/asciidoc.scm"),
            .scip_name = "asciidoc",
        } },
    },
    // JSON
    .{
        .name = "json",
        .file_extensions = &.{".json"},
        .language_names = &.{"json"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "json",
            .query_source = @embedFile("queries/json.scm"),
            .scip_name = "json",
        } },
    },
    // JSONC
    .{
        .name = "jsonc",
        .file_extensions = &.{".jsonc"},
        .language_names = &.{"jsonc"},
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "json",
            .query_source = @embedFile("queries/json.scm"),
            .scip_name = "jsonc",
        } },
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
        .architecture = .{ .imports = true, .calls = true, .containment = true },
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
        .architecture = .{ .imports = true, .calls = true, .containment = true },
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
        .architecture = .{ .imports = true, .calls = true, .containment = true },
        .debug = .{ .dap = .{
            .adapter_command = "python3",
            .adapter_args = &.{ "-m", "debugpy.adapter" },
            .transport = .stdio,
            .launch_extra_args_json =
            \\{"justMyCode":false}
            ,
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
    // Elixir
    .{
        .name = "elixir",
        .file_extensions = &.{ ".ex", ".exs" },
        .language_names = &.{"elixir"},
        .debug = .{ .dap = .{
            .adapter_command = "elixir_ls",
            .adapter_args = &.{},
            .transport = .stdio,
            .dependencies = &.{
                .{ .command = "elixir_ls", .check_args = &.{"--version"}, .error_message = "elixir_ls not found on PATH. Install ElixirLS: https://github.com/elixir-lsp/elixir-ls" },
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
    // Bash
    .{
        .name = "bash",
        .file_extensions = &.{ ".sh", ".bash", ".bats" },
        .language_names = &.{ "bash", "shell", "sh" },
        .indexer = .{ .tree_sitter = .{
            .grammar_name = "bash",
            .query_source = @embedFile("queries/bash.scm"),
            .scip_name = "bash",
        } },
        .architecture = .{ .imports = false, .calls = true, .containment = true },
        .debug = .{ .dap = .{
            .adapter_command = "node",
            .adapter_args = &.{"{entry_point}"},
            .transport = .stdio,
            .dependencies = &.{
                .{ .command = "bash", .check_args = &.{ "-c", "[ ${BASH_VERSINFO[0]} -ge 4 ]" }, .error_message = "Bash 4.0+ is required for bash debugging. Update your bash installation" },
                .{ .command = "node", .check_args = &.{"--version"}, .error_message = "Node.js not found on PATH (required for bash debug adapter)" },
            },
            .adapter_install = .{
                .method = .github_release,
                .repo = "rogalmic/vscode-bash-debug",
                .version = "v0.3.7",
                .asset_pattern = "bash-debug-0.3.7.vsix",
                .extract_format = "zip",
                .install_dir = "bash-debug",
                .entry_point = "bash-debug/extension/out/bashDebug.js",
            },
        } },
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

        // Use first language_name for display (e.g. "elixir" not "cog-elixir"),
        // fall back to manifest name with "cog-" prefix stripped.
        const display_name = if (manifest.language_names.len > 0) blk: {
            const kept = manifest.language_names[0];
            for (manifest.language_names[1..]) |n| allocator.free(n);
            allocator.free(manifest.language_names);
            allocator.free(manifest.name);
            break :blk kept;
        } else blk: {
            const name: []const u8 = manifest.name;
            const prefix = "cog-";
            if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) {
                const stripped = allocator.dupe(u8, name[prefix.len..]) catch break :blk name;
                allocator.free(manifest.name);
                break :blk stripped;
            }
            break :blk name;
        };

        try result.append(allocator, .{
            .name = display_name,
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
                freeDebuggerLeftovers(allocator, manifest.debugger);
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
                freeDebuggerLeftovers(allocator, manifest.debugger);
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
    program_field: ?[]const u8 = null,
    args_field: ?[]const u8 = null,
    args_first_is_program: bool = false,
    skip_entry_stop: bool = false,
    boundary_markers: []const []const u8 = &.{},

    fn toDebugConfig(self: *const AllocatedDebuggerConfig) DebugConfig {
        return switch (self.debugger_type) {
            .native => .{ .native = .{
                .boundary_markers = self.boundary_markers,
            } },
            .dap => .{
                .dap = .{
                    .adapter_command = self.adapter_command orelse "",
                    .adapter_args = self.adapter_args orelse &.{},
                    .transport = if (self.adapter_transport) |t|
                        if (std.mem.eql(u8, t, "tcp")) .tcp else .stdio
                    else
                        .stdio,
                    // launch_args from cog-extension.json flows into launch_extra_args_json
                    .launch_extra_args_json = self.launch_args_template,
                    .launch_args_template = self.launch_args_template,
                    .program_field = self.program_field orelse "program",
                    .args_field = self.args_field orelse "args",
                    .args_first_is_program = self.args_first_is_program,
                    .skip_entry_stop = self.skip_entry_stop,
                    .boundary_markers = self.boundary_markers,
                },
            },
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
        var name_count: usize = 0;
        for (ln_val.array.items) |item| {
            if (item == .string) name_count += 1;
        }
        if (name_count == 0) break :blk @as([]const []const u8, &.{});
        const names = allocator.alloc([]const u8, name_count) catch break :blk @as([]const []const u8, &.{});
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
                    var string_count: usize = 0;
                    for (args_v.array.items) |item| {
                        if (item == .string) string_count += 1;
                    }
                    const adapter_args = try allocator.alloc([]const u8, string_count);
                    var idx: usize = 0;
                    for (args_v.array.items) |item| {
                        if (item == .string) {
                            adapter_args[idx] = try allocator.dupe(u8, item.string);
                            idx += 1;
                        }
                    }
                    result.adapter_args = adapter_args;
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

    // Parse program_field, args_field, args_first_is_program
    if (dbg.get("program_field")) |pf| {
        if (pf == .string) {
            result.program_field = try allocator.dupe(u8, pf.string);
        }
    }
    if (dbg.get("args_field")) |af| {
        if (af == .string) {
            result.args_field = try allocator.dupe(u8, af.string);
        }
    }
    if (dbg.get("args_first_is_program")) |afip| {
        if (afip == .bool) {
            result.args_first_is_program = afip.bool;
        }
    }
    if (dbg.get("skip_entry_stop")) |ses| {
        if (ses == .bool) {
            result.skip_entry_stop = ses.bool;
        }
    }

    // Parse boundary_markers
    if (dbg.get("boundary_markers")) |bm| {
        if (bm == .array) {
            var marker_count: usize = 0;
            for (bm.array.items) |item| {
                if (item == .string) marker_count += 1;
            }
            const markers = try allocator.alloc([]const u8, marker_count);
            var mi: usize = 0;
            for (bm.array.items) |item| {
                if (item == .string) {
                    markers[mi] = try allocator.dupe(u8, item.string);
                    mi += 1;
                }
            }
            result.boundary_markers = markers;
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
                // launch_extra_args_json and launch_args_template may alias the same allocation
                // (for installed extensions, toDebugConfig copies launch_args_template to both).
                // Only free launch_args_template to avoid double-free.
                if (dap.launch_args_template) |l| allocator.free(l);
                // program_field and args_field are heap-allocated when
                // they differ from the comptime defaults.
                if (!std.mem.eql(u8, dap.program_field, "program")) allocator.free(dap.program_field);
                if (!std.mem.eql(u8, dap.args_field, "args")) allocator.free(dap.args_field);
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

/// Free fields from AllocatedDebuggerConfig that are NOT transferred
/// to the Extension's DebugConfig during manifestToExtension/toDebugConfig.
/// - adapter_transport is always converted to an enum (.tcp/.stdio), so
///   the heap string must be freed separately.
/// - For native debuggers, adapter_command/args/launch_args aren't part
///   of NativeConfig and would leak if present.
fn freeDebuggerLeftovers(allocator: std.mem.Allocator, debugger: ?AllocatedDebuggerConfig) void {
    const dbg = debugger orelse return;
    // adapter_transport is converted to an enum in toDebugConfig(); free the string.
    if (dbg.adapter_transport) |t| allocator.free(t);
    // For native debuggers, adapter fields aren't carried into NativeConfig.
    if (dbg.debugger_type == .native) {
        if (dbg.adapter_command) |c| allocator.free(c);
        if (dbg.adapter_args) |args| {
            for (args) |a| allocator.free(a);
            allocator.free(args);
        }
        if (dbg.launch_args_template) |l| allocator.free(l);
        if (dbg.program_field) |f| allocator.free(f);
        if (dbg.args_field) |f| allocator.free(f);
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
    if (dbg.program_field) |f| allocator.free(f);
    if (dbg.args_field) |f| allocator.free(f);
    for (dbg.boundary_markers) |m| allocator.free(m);
    if (dbg.boundary_markers.len > 0) allocator.free(dbg.boundary_markers);
}

const GitHubRepo = struct {
    owner: []const u8,
    repo: []const u8,
};

const StableVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
};

const ReleaseInfo = struct {
    tag_name: []const u8,
    tarball_url: []const u8,
    draft: bool,
    prerelease: bool,
};

const install_metadata_filename = "cog-extension-install.json";

const InstallMetadata = struct {
    source_url: []u8,
    version: []u8,
    tag: []u8,
};

const ResolvedRelease = struct {
    tag_name: []u8,
    version: []u8,
    tarball_url: []u8,
};

const InstallResult = struct {
    name: []u8,
    path: []u8,
    version: []u8,
    tag: []u8,
};

fn normalizeVersionString(tag_name: []const u8) []const u8 {
    if (tag_name.len > 1 and (tag_name[0] == 'v' or tag_name[0] == 'V')) {
        return tag_name[1..];
    }
    return tag_name;
}

fn parseStableVersion(text: []const u8) ?StableVersion {
    var parts = std.mem.splitScalar(u8, text, '.');
    const major_text = parts.next() orelse return null;
    const minor_text = parts.next() orelse return null;
    const patch_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    return .{
        .major = std.fmt.parseUnsigned(u64, major_text, 10) catch return null,
        .minor = std.fmt.parseUnsigned(u64, minor_text, 10) catch return null,
        .patch = std.fmt.parseUnsigned(u64, patch_text, 10) catch return null,
    };
}

fn compareStableVersion(a: StableVersion, b: StableVersion) std.math.Order {
    if (a.major < b.major) return .lt;
    if (a.major > b.major) return .gt;
    if (a.minor < b.minor) return .lt;
    if (a.minor > b.minor) return .gt;
    if (a.patch < b.patch) return .lt;
    if (a.patch > b.patch) return .gt;
    return .eq;
}

fn parseGitHubRepo(url: []const u8) ?GitHubRepo {
    const prefix_https = "https://github.com/";
    const prefix_http = "http://github.com/";
    const prefix_ssh = "ssh://git@github.com/";
    const prefix_scp = "git@github.com:";

    const rest = if (std.mem.startsWith(u8, url, prefix_https))
        url[prefix_https.len..]
    else if (std.mem.startsWith(u8, url, prefix_http))
        url[prefix_http.len..]
    else if (std.mem.startsWith(u8, url, prefix_ssh))
        url[prefix_ssh.len..]
    else if (std.mem.startsWith(u8, url, prefix_scp))
        url[prefix_scp.len..]
    else
        return null;

    const trimmed_slash = std.mem.trimRight(u8, rest, "/");
    const trimmed = if (std.mem.endsWith(u8, trimmed_slash, ".git"))
        trimmed_slash[0 .. trimmed_slash.len - 4]
    else
        trimmed_slash;

    const first_slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return null;
    const owner = trimmed[0..first_slash];
    const repo_and_more = trimmed[first_slash + 1 ..];
    if (owner.len == 0 or repo_and_more.len == 0) return null;

    if (std.mem.indexOfScalar(u8, repo_and_more, '/')) |extra_slash| {
        if (extra_slash == 0 or extra_slash + 1 < repo_and_more.len) return null;
    }
    const repo = if (std.mem.indexOfScalar(u8, repo_and_more, '/')) |extra_slash|
        repo_and_more[0..extra_slash]
    else
        repo_and_more;
    if (repo.len == 0) return null;

    return .{ .owner = owner, .repo = repo };
}

fn chooseRelease(releases: []const ReleaseInfo, requested_version: ?[]const u8) ?ReleaseInfo {
    if (requested_version) |version_text| {
        const normalized_request = normalizeVersionString(version_text);
        for (releases) |release| {
            if (release.draft) continue;
            if (std.mem.eql(u8, normalizeVersionString(release.tag_name), normalized_request)) {
                return release;
            }
        }
        return null;
    }

    var best: ?ReleaseInfo = null;
    var best_version: ?StableVersion = null;
    for (releases) |release| {
        if (release.draft or release.prerelease) continue;
        const stable = parseStableVersion(normalizeVersionString(release.tag_name)) orelse continue;
        if (best_version == null or compareStableVersion(stable, best_version.?) == .gt) {
            best = release;
            best_version = stable;
        }
    }
    return best;
}

fn resolveGithubRelease(allocator: std.mem.Allocator, git_url: []const u8, requested_version: ?[]const u8) !ResolvedRelease {
    const repo = parseGitHubRepo(git_url) orelse {
        printErr("error: extension release installs currently require a GitHub repository URL\n");
        return error.Explained;
    };

    const releases_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases?per_page=100", .{ repo.owner, repo.repo });
    defer allocator.free(releases_url);

    debug_log.log("resolveGithubRelease: fetch releases {s}", .{releases_url});
    const response = curl.get(allocator, releases_url, &.{
        "Accept: application/vnd.github+json",
        "User-Agent: cog-cli",
        "X-GitHub-Api-Version: 2022-11-28",
    }) catch {
        printErr("error: failed to fetch extension releases from GitHub\n");
        return error.Explained;
    };
    defer allocator.free(response.body);
    if (response.status_code != 200) {
        printErr("error: GitHub releases request failed\n");
        return error.Explained;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        printErr("error: invalid GitHub releases response\n");
        return error.Explained;
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        printErr("error: invalid GitHub releases response\n");
        return error.Explained;
    }

    var releases: std.ArrayListUnmanaged(ReleaseInfo) = .empty;
    defer releases.deinit(allocator);

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const tag_value = item.object.get("tag_name") orelse continue;
        const tarball_value = item.object.get("tarball_url") orelse continue;
        const draft_value = item.object.get("draft") orelse continue;
        const prerelease_value = item.object.get("prerelease") orelse continue;
        if (tag_value != .string or tarball_value != .string or draft_value != .bool or prerelease_value != .bool) continue;
        try releases.append(allocator, .{
            .tag_name = tag_value.string,
            .tarball_url = tarball_value.string,
            .draft = draft_value.bool,
            .prerelease = prerelease_value.bool,
        });
    }

    if (releases.items.len == 0) {
        printErr("error: no GitHub releases found for extension repository\n");
        return error.Explained;
    }

    const selected = chooseRelease(releases.items, requested_version) orelse {
        if (requested_version != null) {
            printErr("error: requested extension version was not found in GitHub releases\n");
        } else {
            printErr("error: no stable semantic-version GitHub release found for extension repository\n");
        }
        return error.Explained;
    };
    debug_log.log("resolveGithubRelease: selected tag {s}", .{selected.tag_name});

    return .{
        .tag_name = try allocator.dupe(u8, selected.tag_name),
        .version = try allocator.dupe(u8, normalizeVersionString(selected.tag_name)),
        .tarball_url = try allocator.dupe(u8, selected.tarball_url),
    };
}

fn freeResolvedRelease(allocator: std.mem.Allocator, release: *const ResolvedRelease) void {
    allocator.free(release.tag_name);
    allocator.free(release.version);
    allocator.free(release.tarball_url);
}

fn freeInstallMetadata(allocator: std.mem.Allocator, metadata: *const InstallMetadata) void {
    allocator.free(metadata.source_url);
    allocator.free(metadata.version);
    allocator.free(metadata.tag);
}

fn freeInstallResult(allocator: std.mem.Allocator, result: *const InstallResult) void {
    allocator.free(result.name);
    allocator.free(result.path);
    allocator.free(result.version);
    allocator.free(result.tag);
}

fn metadataPath(allocator: std.mem.Allocator, ext_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ ext_dir, install_metadata_filename });
}

fn writeInstallMetadata(allocator: std.mem.Allocator, ext_dir: []const u8, source_url: []const u8, release: ResolvedRelease) !void {
    const path = try metadataPath(allocator, ext_dir);
    defer allocator.free(path);
    debug_log.log("writeInstallMetadata: {s}", .{path});

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("source_url");
    try s.write(source_url);
    try s.objectField("version");
    try s.write(release.version);
    try s.objectField("tag");
    try s.write(release.tag_name);
    try s.endObject();
    const body = try aw.toOwnedSlice();
    defer allocator.free(body);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(body);
}

fn readInstallMetadata(allocator: std.mem.Allocator, ext_dir: []const u8) !InstallMetadata {
    const path = try metadataPath(allocator, ext_dir);
    defer allocator.free(path);
    debug_log.log("readInstallMetadata: {s}", .{path});

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const body = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInstallMetadata;

    const source_url_value = parsed.value.object.get("source_url") orelse return error.InvalidInstallMetadata;
    const version_value = parsed.value.object.get("version") orelse return error.InvalidInstallMetadata;
    const tag_value = parsed.value.object.get("tag") orelse return error.InvalidInstallMetadata;
    if (source_url_value != .string or version_value != .string or tag_value != .string) return error.InvalidInstallMetadata;

    return .{
        .source_url = try allocator.dupe(u8, source_url_value.string),
        .version = try allocator.dupe(u8, version_value.string),
        .tag = try allocator.dupe(u8, tag_value.string),
    };
}

fn deleteTreeIfExistsAbsolute(path: []const u8) !void {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const parent_path = std.fs.path.dirname(path) orelse return error.FileNotFound;
    const child_name = std.fs.path.basename(path);
    var parent_dir = std.fs.openDirAbsolute(parent_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent_dir.close();
    try parent_dir.deleteTree(child_name);
}

fn extractTarball(allocator: std.mem.Allocator, tarball_path: []const u8, output_dir: []const u8) !void {
    debug_log.log("extractTarball: {s} -> {s}", .{ tarball_path, output_dir });
    var tar = std.process.Child.init(&.{ "tar", "xzf", tarball_path, "--strip-components=1", "-C", output_dir }, allocator);
    tar.stdin_behavior = .Ignore;
    tar.stdout_behavior = .Inherit;
    tar.stderr_behavior = .Inherit;
    try tar.spawn();
    const term = try tar.wait();
    if (term.Exited != 0) return error.ExtractFailed;
}

fn downloadReleaseTarball(allocator: std.mem.Allocator, tarball_url: []const u8, output_path: []const u8) !void {
    debug_log.log("downloadReleaseTarball: {s}", .{tarball_url});
    const response = curl.get(allocator, tarball_url, &.{
        "Accept: application/vnd.github+json",
        "User-Agent: cog-cli",
        "X-GitHub-Api-Version: 2022-11-28",
    }) catch return error.DownloadFailed;
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.DownloadFailed;

    const file = try std.fs.createFileAbsolute(output_path, .{});
    defer file.close();
    try file.writeAll(response.body);
}

fn installExtensionToDir(allocator: std.mem.Allocator, git_url: []const u8, requested_version: ?[]const u8, install_dir_name: ?[]const u8) !InstallResult {
    const resolved_name = install_dir_name orelse blk: {
        var name = std.fs.path.basename(git_url);
        if (std.mem.endsWith(u8, name, ".git")) {
            name = name[0 .. name.len - 4];
        }
        break :blk name;
    };

    if (resolved_name.len == 0) {
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

    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ext_base, resolved_name });
    defer allocator.free(ext_dir);

    const tmp_dir = try std.fmt.allocPrint(allocator, "{s}/{s}.tmp", .{ ext_base, resolved_name });
    defer allocator.free(tmp_dir);

    const tarball_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ ext_base, resolved_name });
    defer allocator.free(tarball_path);

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

    const release = try resolveGithubRelease(allocator, git_url, requested_version);
    defer freeResolvedRelease(allocator, &release);

    deleteTreeIfExistsAbsolute(tmp_dir) catch {
        printErr("error: failed to clean temporary extension directory\n");
        return error.Explained;
    };
    std.fs.deleteFileAbsolute(tarball_path) catch {};

    std.fs.makeDirAbsolute(tmp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("error: failed to create temporary extension directory\n");
            return error.Explained;
        },
    };
    errdefer deleteTreeIfExistsAbsolute(tmp_dir) catch {};
    errdefer std.fs.deleteFileAbsolute(tarball_path) catch {};

    downloadReleaseTarball(allocator, release.tarball_url, tarball_path) catch {
        printErr("error: failed to download extension release tarball\n");
        return error.Explained;
    };
    extractTarball(allocator, tarball_path, tmp_dir) catch {
        printErr("error: failed to extract extension release tarball\n");
        return error.Explained;
    };
    std.fs.deleteFileAbsolute(tarball_path) catch {};

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/cog-extension.json", .{tmp_dir});
    defer allocator.free(manifest_path);

    const manifest = readManifest(allocator, manifest_path) catch {
        printErr("error: no valid cog-extension.json found in extension release\n");
        return error.Explained;
    };
    defer freeManifest(allocator, &manifest);

    const build_args: []const []const u8 = &.{ "/bin/sh", "-c", manifest.build_cmd };
    var build_proc = std.process.Child.init(build_args, allocator);
    build_proc.stderr_behavior = .Inherit;
    build_proc.stdout_behavior = .Inherit;
    build_proc.cwd = tmp_dir;
    debug_log.log("installExtensionToDir: build in {s}", .{tmp_dir});
    try build_proc.spawn();
    const build_term = try build_proc.wait();
    if (build_term.Exited != 0) {
        printErr("error: build command failed\n");
        return error.Explained;
    }

    const bin_path = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ tmp_dir, manifest.name });
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

    writeInstallMetadata(allocator, tmp_dir, git_url, release) catch {
        printErr("error: failed to write extension install metadata\n");
        return error.Explained;
    };

    deleteTreeIfExistsAbsolute(ext_dir) catch {
        printErr("error: failed to replace existing extension install\n");
        return error.Explained;
    };

    var ext_parent_dir = std.fs.openDirAbsolute(ext_base, .{}) catch {
        printErr("error: failed to open extensions directory\n");
        return error.Explained;
    };
    defer ext_parent_dir.close();
    ext_parent_dir.rename(std.fs.path.basename(tmp_dir), std.fs.path.basename(ext_dir)) catch {
        printErr("error: failed to finalize extension install\n");
        return error.Explained;
    };

    return .{
        .name = try allocator.dupe(u8, manifest.name),
        .path = try allocator.dupe(u8, ext_dir),
        .version = try allocator.dupe(u8, release.version),
        .tag = try allocator.dupe(u8, release.tag_name),
    };
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

/// Install an extension from a GitHub release tarball.
pub fn installExtension(allocator: std.mem.Allocator, git_url: []const u8, requested_version: ?[]const u8) !void {
    debug_log.log("installExtension: {s} version={?s}", .{ git_url, requested_version });
    const install_result = try installExtensionToDir(allocator, git_url, requested_version, null);
    defer freeInstallResult(allocator, &install_result);

    // Output JSON
    const json_mod = std.json;
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: json_mod.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("name");
    try s.write(install_result.name);
    try s.objectField("installed");
    try s.write(true);
    try s.objectField("path");
    try s.write(install_result.path);
    try s.objectField("version");
    try s.write(install_result.version);
    try s.objectField("tag");
    try s.write(install_result.tag);
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

pub fn updateExtensions(allocator: std.mem.Allocator, requested_name: ?[]const u8) !void {
    debug_log.log("updateExtensions: start name={?s}", .{requested_name});
    const config_dir = paths.getGlobalConfigDir(allocator) catch {
        printErr("error: could not determine config directory\n");
        return error.Explained;
    };
    defer allocator.free(config_dir);

    const ext_base = try std.fmt.allocPrint(allocator, "{s}/extensions", .{config_dir});
    defer allocator.free(ext_base);

    var dir = std.fs.openDirAbsolute(ext_base, .{ .iterate = true }) catch {
        printErr("error: no installed extensions found\n");
        return error.Explained;
    };
    defer dir.close();

    var iter = dir.iterate();
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("updated");
    try s.beginArray();

    var updated_count: usize = 0;
    var matched_count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (requested_name) |name| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            matched_count += 1;
        }
        debug_log.log("updateExtensions: inspect {s}", .{entry.name});
        const ext_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ext_base, entry.name });
        defer allocator.free(ext_dir);

        const metadata = readInstallMetadata(allocator, ext_dir) catch |err| switch (err) {
            error.FileNotFound, error.InvalidInstallMetadata => {
                debug_log.log("updateExtensions: skip {s}, missing metadata", .{entry.name});
                continue;
            },
            else => return err,
        };
        defer freeInstallMetadata(allocator, &metadata);

        const latest_release = try resolveGithubRelease(allocator, metadata.source_url, null);
        defer freeResolvedRelease(allocator, &latest_release);
        if (std.mem.eql(u8, latest_release.tag_name, metadata.tag)) {
            debug_log.log("updateExtensions: {s} already current at {s}", .{ entry.name, metadata.tag });
            continue;
        }

        debug_log.log("updateExtensions: {s} {s} -> {s}", .{ entry.name, metadata.tag, latest_release.tag_name });

        const install_result = try installExtensionToDir(allocator, metadata.source_url, null, entry.name);
        defer freeInstallResult(allocator, &install_result);

        try s.beginObject();
        try s.objectField("name");
        try s.write(install_result.name);
        try s.objectField("path");
        try s.write(install_result.path);
        try s.objectField("from_version");
        try s.write(metadata.version);
        try s.objectField("to_version");
        try s.write(install_result.version);
        try s.objectField("tag");
        try s.write(install_result.tag);
        try s.endObject();
        updated_count += 1;
    }

    if (requested_name != null and matched_count == 0) {
        printErr("error: installed extension not found: ");
        printErr(requested_name.?);
        printErr("\n");
        return error.Explained;
    }

    try s.endArray();
    try s.objectField("updated_count");
    try s.write(updated_count);
    if (requested_name) |name| {
        try s.objectField("name");
        try s.write(name);
    }
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

test "parseGitHubRepo supports https and scp urls" {
    const https_repo = parseGitHubRepo("https://github.com/trycog/cog-zig.git");
    try std.testing.expect(https_repo != null);
    try std.testing.expectEqualStrings("trycog", https_repo.?.owner);
    try std.testing.expectEqualStrings("cog-zig", https_repo.?.repo);

    const scp_repo = parseGitHubRepo("git@github.com:trycog/cog-zig.git");
    try std.testing.expect(scp_repo != null);
    try std.testing.expectEqualStrings("trycog", scp_repo.?.owner);
    try std.testing.expectEqualStrings("cog-zig", scp_repo.?.repo);
}

test "chooseRelease selects highest stable version by default" {
    const releases = [_]ReleaseInfo{
        .{ .tag_name = "v0.74.0", .tarball_url = "https://example.com/74", .draft = false, .prerelease = false },
        .{ .tag_name = "v0.75.0-rc.1", .tarball_url = "https://example.com/75rc", .draft = false, .prerelease = true },
        .{ .tag_name = "v0.75.0", .tarball_url = "https://example.com/75", .draft = false, .prerelease = false },
    };
    const selected = chooseRelease(&releases, null);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("v0.75.0", selected.?.tag_name);
}

test "chooseRelease matches exact requested version after v normalization" {
    const releases = [_]ReleaseInfo{
        .{ .tag_name = "v0.75.0", .tarball_url = "https://example.com/75", .draft = false, .prerelease = false },
        .{ .tag_name = "v0.76.0", .tarball_url = "https://example.com/76", .draft = false, .prerelease = false },
    };
    const selected = chooseRelease(&releases, "0.75.0");
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("v0.75.0", selected.?.tag_name);
    try std.testing.expect(chooseRelease(&releases, "0.75") == null);
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

test "architecture capability declarations match builtin query captures" {
    for (builtins) |ext| {
        try std.testing.expect(validateArchitectureCapabilities(ext));
    }
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
