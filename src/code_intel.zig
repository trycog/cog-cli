const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const scip = @import("scip.zig");
const scip_encode = @import("scip_encode.zig");
const protobuf = @import("protobuf.zig");
const help = @import("help_text.zig");
const tui = @import("tui.zig");
const settings_mod = @import("settings.zig");
const paths = @import("paths.zig");
const extensions = @import("extensions.zig");
const tree_sitter_indexer = @import("tree_sitter_indexer.zig");

// ANSI styles
const dim = "\x1B[2m";
const reset = "\x1B[0m";

// ── Helpers ─────────────────────────────────────────────────────────────

fn printStdout(text: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(text) catch {};
    w.interface.writeByte('\n') catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

fn findFlag(args: []const [:0]const u8, flag: []const u8) ?[:0]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 < args.len) return args[i + 1];
        }
    }
    return null;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

// ── Index location ──────────────────────────────────────────────────────

/// Get the path to the index.scip file.
fn getIndexPath(allocator: std.mem.Allocator) ![]const u8 {
    const cog_dir = paths.findCogDir(allocator) catch {
        printErr("error: no .cog directory found. Run " ++ dim ++ "cog code/index" ++ reset ++ " first.\n");
        return error.Explained;
    };
    defer allocator.free(cog_dir);
    return std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
}

// ── CodeIndex ───────────────────────────────────────────────────────────

const DefInfo = struct {
    path: []const u8,
    line: i32,
    kind: i32,
    display_name: []const u8,
    documentation: []const []const u8,
};

const RefInfo = struct {
    path: []const u8,
    line: i32,
    roles: []const u8,
};

const CodeIndex = struct {
    index: scip.Index,
    symbol_to_defs: std.StringHashMapUnmanaged(DefInfo),
    symbol_to_refs: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(RefInfo)),
    path_to_doc_idx: std.StringHashMapUnmanaged(usize),
    /// Backing data buffer for zero-copy protobuf decoder. Must outlive the index.
    backing_data: ?[]const u8 = null,

    fn build(allocator: std.mem.Allocator, index: scip.Index) !CodeIndex {
        var symbol_to_defs: std.StringHashMapUnmanaged(DefInfo) = .empty;
        var symbol_to_refs: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(RefInfo)) = .empty;
        var path_to_doc_idx: std.StringHashMapUnmanaged(usize) = .empty;

        for (index.documents, 0..) |doc, doc_idx| {
            try path_to_doc_idx.put(allocator, doc.relative_path, doc_idx);

            // Process symbol definitions from document's symbols
            for (doc.symbols) |sym| {
                if (sym.symbol.len > 0) {
                    // Find the definition occurrence line for this symbol
                    var def_line: i32 = 0;
                    for (doc.occurrences) |occ| {
                        if (std.mem.eql(u8, occ.symbol, sym.symbol) and scip.SymbolRole.isDefinition(occ.symbol_roles)) {
                            def_line = occ.range.start_line;
                            break;
                        }
                    }
                    try symbol_to_defs.put(allocator, sym.symbol, .{
                        .path = doc.relative_path,
                        .line = def_line,
                        .kind = sym.kind,
                        .display_name = sym.display_name,
                        .documentation = sym.documentation,
                    });
                }
            }

            // Process all occurrences for references
            for (doc.occurrences) |occ| {
                if (occ.symbol.len == 0) continue;
                const entry = try symbol_to_refs.getOrPut(allocator, occ.symbol);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                }
                try entry.value_ptr.append(allocator, .{
                    .path = doc.relative_path,
                    .line = occ.range.start_line,
                    .roles = scip.SymbolRole.describe(occ.symbol_roles),
                });
            }
        }

        // Also process external_symbols
        for (index.external_symbols) |sym| {
            if (sym.symbol.len > 0 and !symbol_to_defs.contains(sym.symbol)) {
                try symbol_to_defs.put(allocator, sym.symbol, .{
                    .path = "",
                    .line = 0,
                    .kind = sym.kind,
                    .display_name = sym.display_name,
                    .documentation = sym.documentation,
                });
            }
        }

        return .{
            .index = index,
            .symbol_to_defs = symbol_to_defs,
            .symbol_to_refs = symbol_to_refs,
            .path_to_doc_idx = path_to_doc_idx,
        };
    }

    fn deinit(self: *CodeIndex, allocator: std.mem.Allocator) void {
        self.symbol_to_defs.deinit(allocator);
        var ref_iter = self.symbol_to_refs.iterator();
        while (ref_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.symbol_to_refs.deinit(allocator);
        self.path_to_doc_idx.deinit(allocator);
        scip.freeIndex(allocator, &self.index);
        if (self.backing_data) |data| allocator.free(data);
    }

    /// Find symbols matching a name (searches display_name and extracted name).
    /// Returns matches sorted by relevance score (exact match > non-test > partial match).
    fn findSymbol(self: *const CodeIndex, name: []const u8, kind_filter: ?[]const u8) MatchList {
        var matches: MatchList = .{};
        var iter = self.symbol_to_defs.iterator();
        while (iter.next()) |entry| {
            const sym_name = entry.key_ptr.*;
            const def = entry.value_ptr.*;

            // Match against display_name
            const display_match = def.display_name.len > 0 and
                std.ascii.eqlIgnoreCase(def.display_name, name);

            // Match against extracted name from symbol string
            const extracted = scip.extractSymbolName(sym_name);
            const extracted_match = std.ascii.eqlIgnoreCase(extracted, name);

            if (display_match or extracted_match) {
                // Apply kind filter
                if (kind_filter) |kf| {
                    const k = scip.kindName(def.kind);
                    if (!std.ascii.eqlIgnoreCase(k, kf)) continue;
                }

                if (matches.len < max_matches) {
                    // Calculate relevance score
                    var score: u8 = 0;

                    // Exact case-sensitive match (highest priority)
                    if (std.mem.eql(u8, def.display_name, name) or std.mem.eql(u8, extracted, name)) {
                        score += 100;
                    }

                    // Not in a test file
                    if (!pathIsTest(def.path)) {
                        score += 50;
                    }

                    // Shorter paths (less nested) rank higher
                    const path_depth = countPathSeparators(def.path);
                    if (path_depth <= 2) score += 10;

                    matches.items[matches.len] = .{ .symbol = sym_name, .def = def, .score = score };
                    matches.len += 1;
                }
            }
        }

        // Sort by score descending
        sortMatchesByScore(&matches);
        return matches;
    }

    /// Check if a path appears to be a test file.
    fn pathIsTest(path: []const u8) bool {
        return std.mem.indexOf(u8, path, "test") != null or
               std.mem.indexOf(u8, path, "__tests__") != null or
               std.mem.indexOf(u8, path, "spec") != null or
               std.mem.endsWith(u8, path, ".test.js") or
               std.mem.endsWith(u8, path, ".test.ts") or
               std.mem.endsWith(u8, path, ".spec.js") or
               std.mem.endsWith(u8, path, ".spec.ts") or
               std.mem.endsWith(u8, path, "_test.go") or
               std.mem.endsWith(u8, path, "_test.py");
    }

    /// Count path separators to estimate nesting depth.
    fn countPathSeparators(path: []const u8) usize {
        var count: usize = 0;
        for (path) |c| {
            if (c == '/') count += 1;
        }
        return count;
    }

    /// Sort matches by score (descending), using insertion sort for small arrays.
    fn sortMatchesByScore(matches: *MatchList) void {
        if (matches.len <= 1) return;

        var i: usize = 1;
        while (i < matches.len) : (i += 1) {
            const key = matches.items[i];
            var j: usize = i;
            while (j > 0 and matches.items[j - 1].score < key.score) : (j -= 1) {
                matches.items[j] = matches.items[j - 1];
            }
            matches.items[j] = key;
        }
    }

    const max_matches = 64;
    const MatchEntry = struct { symbol: []const u8, def: DefInfo, score: u8 = 0 };
    const MatchList = struct {
        items: [max_matches]MatchEntry = undefined,
        len: usize = 0,
    };
};

/// Load and decode the SCIP index from .cog/index.scip.
fn loadIndex(allocator: std.mem.Allocator) !CodeIndex {
    const index_path = try getIndexPath(allocator);
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch {
        printErr("error: no index found. Run " ++ dim ++ "cog code/index" ++ reset ++ " first.\n");
        return error.Explained;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch {
        printErr("error: failed to read index file\n");
        return error.Explained;
    };

    const index = scip.decode(allocator, data) catch {
        allocator.free(data);
        printErr("error: failed to decode index file (corrupt or invalid format)\n");
        return error.Explained;
    };

    var ci = CodeIndex.build(allocator, index) catch {
        allocator.free(data);
        printErr("error: failed to build code index\n");
        return error.Explained;
    };
    ci.backing_data = data;
    return ci;
}

// ── Commands ────────────────────────────────────────────────────────────

pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, subcmd, "code/index")) return codeIndex(allocator, args);
    if (std.mem.eql(u8, subcmd, "code/query")) return codeQuery(allocator, args);
    if (std.mem.eql(u8, subcmd, "code/status")) return codeStatus(allocator, args);
    if (std.mem.eql(u8, subcmd, "code/edit")) return codeEdit(allocator, args);
    if (std.mem.eql(u8, subcmd, "code/create")) return codeCreate(allocator, args);
    if (std.mem.eql(u8, subcmd, "code/delete")) return codeDelete(allocator, args);
    if (std.mem.eql(u8, subcmd, "code/rename")) return codeRename(allocator, args);

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

// ── code/index ──────────────────────────────────────────────────────────

fn codeIndex(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_index);
        return;
    }

    // Collect positional arguments (non-flag args) as patterns
    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    defer patterns.deinit(allocator);
    for (args) |arg| {
        const a: []const u8 = arg;
        if (!std.mem.startsWith(u8, a, "--")) {
            try patterns.append(allocator, a);
        }
    }

    // Default to "**/*" (everything, recursive) when no patterns given
    if (patterns.items.len == 0) {
        try patterns.append(allocator, "**/*");
    }

    const cog_dir = paths.findOrCreateCogDir(allocator) catch {
        printErr("error: failed to create .cog directory\n");
        return error.Explained;
    };
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    // Create .cog directory if needed
    std.fs.makeDirAbsolute(cog_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            printErr("error: failed to create .cog directory\n");
            return error.Explained;
        },
    };

    // Load existing index (or start empty)
    // Track backing data buffers — protobuf decoder is zero-copy so string
    // slices point into these buffers. They must outlive the index.
    var backing_buffers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (backing_buffers.items) |buf| allocator.free(buf);
        backing_buffers.deinit(allocator);
    }

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    if (loaded.backing_data) |data| {
        backing_buffers.append(allocator, data) catch {};
    }

    // Expand all patterns to a file list
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    for (patterns.items) |pattern| {
        collectGlobFiles(allocator, pattern, &files) catch continue;
    }

    if (files.items.len == 0) {
        printErr("error: no files matched\n");
        return error.Explained;
    }

    // TTY progress display
    const show_progress = tui.isStderrTty();
    const total_files = files.items.len;
    if (show_progress) {
        tui.header();
        tui.progressStart(total_files);
    }

    var indexed_count: usize = 0;
    var total_symbols: usize = 0;

    // Tree-sitter per-file indexing
    var indexer = tree_sitter_indexer.Indexer.init();
    defer indexer.deinit();

    // Track extensions that need external indexers (not supported by tree-sitter)
    var seen_names: [16][]const u8 = undefined;
    var unique_exts: [16]extensions.Extension = undefined;
    var num_unique: usize = 0;

    for (files.items) |file_path| {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) continue;

        // Try tree-sitter first
        if (tree_sitter_indexer.detectLanguage(ext)) |lang| {
            if (show_progress) {
                tui.progressUpdate(indexed_count, total_files, total_symbols, file_path);
            }

            // Read source file
            const source = readFileContents(allocator, file_path) orelse continue;
            defer allocator.free(source);

            // Index with tree-sitter
            const result = indexer.indexFile(allocator, source, file_path, lang) catch continue;
            backing_buffers.append(allocator, result.string_data) catch {};
            mergeDocument(allocator, &master_index, result.doc);
            indexed_count += 1;
            total_symbols += result.doc.symbols.len;

            if (show_progress) {
                tui.progressUpdate(indexed_count, total_files, total_symbols, file_path);
            }
        } else {
            // Track for external indexer fallback
            const extension = extensions.resolveByExtension(allocator, ext) orelse continue;
            var found = false;
            for (seen_names[0..num_unique]) |name| {
                if (std.mem.eql(u8, name, extension.name)) {
                    found = true;
                    break;
                }
            }
            if (!found and num_unique < 16) {
                seen_names[num_unique] = extension.name;
                unique_exts[num_unique] = extension;
                num_unique += 1;
            }
        }
    }

    // Invoke external indexers for unsupported languages
    // Use the first pattern's prefix as the project root for external indexers,
    // or "." if there are multiple patterns (shell-expanded).
    const ext_target: []const u8 = if (patterns.items.len == 1)
        globPrefix(patterns.items[0])
    else
        ".";
    for (unique_exts[0..num_unique]) |*ext| {
        if (show_progress) {
            tui.progressUpdate(indexed_count, total_files, total_symbols, ext.name);
        }

        const result = invokeProjectIndexer(allocator, ext_target, ext) catch continue;

        if (result.backing_data) |data| {
            backing_buffers.append(allocator, data) catch {};
        }

        for (result.index.documents) |doc| {
            mergeDocument(allocator, &master_index, doc);
            indexed_count += 1;
            total_symbols += doc.symbols.len;
            if (show_progress) {
                tui.progressUpdate(indexed_count, total_files, total_symbols, doc.relative_path);
            }
        }

        allocator.free(result.index.documents);
        for (result.index.external_symbols) |*sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(result.index.external_symbols);
    }

    // Encode and write the master index
    const encoded = scip_encode.encodeIndex(allocator, master_index) catch {
        printErr("error: failed to encode index\n");
        return error.Explained;
    };
    defer allocator.free(encoded);

    const out_file = std.fs.createFileAbsolute(index_path, .{}) catch {
        printErr("error: failed to write index file\n");
        return error.Explained;
    };
    defer out_file.close();
    out_file.writeAll(encoded) catch {
        printErr("error: failed to write index file\n");
        return error.Explained;
    };

    // Add external symbols to total count
    total_symbols += master_index.external_symbols.len;

    if (show_progress) {
        tui.progressFinish(indexed_count, total_symbols, 0, index_path);
    }

    // Output JSON stats
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("files_indexed");
    try s.write(indexed_count);
    try s.objectField("documents");
    try s.write(master_index.documents.len);
    try s.objectField("symbols");
    try s.write(total_symbols);
    try s.objectField("path");
    try s.write(index_path);
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

/// Result from loading/decoding a SCIP index.
/// The backing_data buffer must stay alive as long as the index is used,
/// because the protobuf decoder is zero-copy (string slices point into it).
const IndexResult = struct {
    index: scip.Index,
    backing_data: ?[]const u8,
};

/// Load existing SCIP index or return an empty one.
/// Caller must free backing_data after the index is no longer needed.
fn loadExistingIndex(allocator: std.mem.Allocator, index_path: []const u8) IndexResult {
    const file = std.fs.openFileAbsolute(index_path, .{}) catch return .{ .index = emptyIndex(), .backing_data = null };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return .{ .index = emptyIndex(), .backing_data = null };

    const index = scip.decode(allocator, data) catch {
        allocator.free(data);
        return .{ .index = emptyIndex(), .backing_data = null };
    };

    return .{ .index = index, .backing_data = data };
}

fn emptyIndex() scip.Index {
    return .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "cog", .version = "1.0" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &.{},
        .external_symbols = &.{},
    };
}

/// Read a file's contents. Returns null on failure.
fn readFileContents(allocator: std.mem.Allocator, file_path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch null;
}

/// Recursively collect files from a directory.
fn collectFiles(allocator: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden dirs and common non-source dirs
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;

        const child_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            try collectFiles(allocator, child_path, out);
            allocator.free(child_path);
        } else if (entry.kind == .file) {
            try out.append(allocator, child_path);
        } else {
            allocator.free(child_path);
        }
    }
}

/// Match a path against a glob pattern.
/// Supports: `*` (any non-`/` chars), `**` (any path segments), `?` (any single non-`/` char).
fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0; // pattern index
    var si: usize = 0; // path (string) index

    // For `*` backtracking
    var star_pi: usize = 0;
    var star_si: usize = 0;
    var has_star = false;

    while (si < path.len or pi < pattern.len) {
        if (pi < pattern.len) {
            // Handle `**`
            if (pi + 1 < pattern.len and pattern[pi] == '*' and pattern[pi + 1] == '*') {
                // Skip the `**`
                pi += 2;
                // Skip trailing `/` after `**`
                if (pi < pattern.len and pattern[pi] == '/') pi += 1;
                // `**` at end matches everything remaining
                if (pi >= pattern.len) return true;
                // Try matching the rest of the pattern at every remaining position
                while (si <= path.len) {
                    if (globMatch(pattern[pi..], path[si..])) return true;
                    if (si < path.len) {
                        si += 1;
                    } else break;
                }
                return false;
            }

            // Handle `*` (non-`/` chars only)
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_si = si;
                has_star = true;
                pi += 1;
                continue;
            }

            if (si < path.len) {
                // Handle `?` (any single non-`/` char)
                if (pattern[pi] == '?' and path[si] != '/') {
                    pi += 1;
                    si += 1;
                    continue;
                }

                // Literal match
                if (pattern[pi] == path[si]) {
                    pi += 1;
                    si += 1;
                    continue;
                }
            }
        }

        // Mismatch — backtrack to last `*` if possible
        if (has_star and star_si < path.len and path[star_si] != '/') {
            star_si += 1;
            si = star_si;
            pi = star_pi + 1;
            continue;
        }

        return false;
    }

    return true;
}

/// Extract the literal directory prefix from a glob pattern (everything before the first wildcard).
/// Returns "." if the pattern starts with a wildcard.
fn globPrefix(pattern: []const u8) []const u8 {
    // Find the first wildcard character
    var first_wild: usize = pattern.len;
    for (pattern, 0..) |c, i| {
        if (c == '*' or c == '?') {
            first_wild = i;
            break;
        }
    }

    if (first_wild == 0) return ".";

    // Walk back to the last `/` before the wildcard
    var last_slash: usize = 0;
    var found_slash = false;
    for (pattern[0..first_wild], 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found_slash = true;
        }
    }

    if (!found_slash) return ".";
    return pattern[0..last_slash];
}

/// Collect files matching a glob pattern.
/// Extracts the literal prefix directory, walks it recursively, and filters
/// each file path against the full glob pattern using `globMatch`.
fn collectGlobFiles(allocator: std.mem.Allocator, pattern: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const prefix = globPrefix(pattern);

    // Check if the pattern is a literal file path (no wildcards at all)
    const has_wildcard = for (pattern) |c| {
        if (c == '*' or c == '?') break true;
    } else false;

    if (!has_wildcard) {
        // Literal path — check if it's a file or directory
        const stat = std.fs.cwd().statFile(pattern) catch return;
        if (stat.kind == .file) {
            try out.append(allocator, try allocator.dupe(u8, pattern));
        } else if (stat.kind == .directory) {
            // Literal directory — collect all files recursively
            try collectFiles(allocator, pattern, out);
        }
        return;
    }

    // Walk the prefix directory and match against the pattern
    try collectGlobFilesRecursive(allocator, prefix, pattern, out);
}

/// Recursively walk a directory, building relative paths and matching against a glob pattern.
fn collectGlobFilesRecursive(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    pattern: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden dirs and common non-source dirs
        if (entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;

        const child_path = if (std.mem.eql(u8, dir_path, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });

        if (entry.kind == .directory) {
            try collectGlobFilesRecursive(allocator, child_path, pattern, out);
            allocator.free(child_path);
        } else if (entry.kind == .file) {
            if (globMatch(pattern, child_path)) {
                try out.append(allocator, child_path);
            } else {
                allocator.free(child_path);
            }
        } else {
            allocator.free(child_path);
        }
    }
}

/// Result from invoking a per-file indexer.
const DocumentResult = struct {
    doc: scip.Document,
    backing_data: []const u8,
};

/// Invoke an indexer for a single file, decode the SCIP output, return the document.
/// Caller must free backing_data after the document is no longer needed.
fn invokeIndexerForFile(allocator: std.mem.Allocator, file_path: []const u8, ext: *const extensions.Extension) !DocumentResult {
    // Create temp file for SCIP output
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/cog-index-{d}.scip", .{std.crypto.random.int(u64)});
    defer allocator.free(tmp_path);
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Substitute {file} and {output} in extension args
    const subs: []const settings_mod.Substitution = &.{
        .{ .key = "{file}", .value = file_path },
        .{ .key = "{output}", .value = tmp_path },
    };
    const sub_args = try settings_mod.substituteArgs(allocator, ext.args, subs);
    defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

    // Build full command
    const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
    defer allocator.free(full_args);
    full_args[0] = ext.command;
    @memcpy(full_args[1..], sub_args);

    // Run indexer (output goes to temp file, not stdout/stderr)
    var child = std.process.Child.init(full_args, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();

    if (term.Exited != 0) return error.IndexerFailed;

    // Read and decode the temp SCIP output
    const tmp_file = try std.fs.openFileAbsolute(tmp_path, .{});
    defer tmp_file.close();
    const tmp_data = try tmp_file.readToEndAlloc(allocator, 256 * 1024 * 1024);

    var tmp_index = scip.decode(allocator, tmp_data) catch |err| {
        allocator.free(tmp_data);
        return err;
    };

    if (tmp_index.documents.len == 0) {
        scip.freeIndex(allocator, &tmp_index);
        allocator.free(tmp_data);
        return error.NoDocuments;
    }

    // Free everything except the first document (which we return)
    for (tmp_index.documents[1..]) |*doc| {
        scip.freeDocument(allocator, doc);
    }
    for (tmp_index.external_symbols) |*sym| {
        allocator.free(sym.documentation);
        allocator.free(sym.relationships);
    }
    allocator.free(tmp_index.external_symbols);

    // Take ownership of the first document
    const doc = tmp_index.documents[0];
    allocator.free(tmp_index.documents);

    return .{
        .doc = .{
            .language = doc.language,
            .relative_path = file_path,
            .occurrences = doc.occurrences,
            .symbols = doc.symbols,
        },
        .backing_data = tmp_data,
    };
}

/// Invoke an indexer for a project directory, decode the SCIP output, return the full index.
/// Caller must free backing_data after the index is no longer needed.
fn invokeProjectIndexer(allocator: std.mem.Allocator, target_path: []const u8, ext: *const extensions.Extension) !IndexResult {
    // Create temp file for SCIP output
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/cog-index-{d}.scip", .{std.crypto.random.int(u64)});
    defer allocator.free(tmp_path);
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Substitute {file} and {output} in extension args
    const subs: []const settings_mod.Substitution = &.{
        .{ .key = "{file}", .value = target_path },
        .{ .key = "{output}", .value = tmp_path },
    };
    const sub_args = try settings_mod.substituteArgs(allocator, ext.args, subs);
    defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

    // Build full command
    const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
    defer allocator.free(full_args);
    full_args[0] = ext.command;
    @memcpy(full_args[1..], sub_args);

    // Run indexer
    var child = std.process.Child.init(full_args, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();

    if (term.Exited != 0) return error.IndexerFailed;

    // Read and decode the SCIP output
    const tmp_file = try std.fs.openFileAbsolute(tmp_path, .{});
    defer tmp_file.close();
    const tmp_data = try tmp_file.readToEndAlloc(allocator, 256 * 1024 * 1024);

    const index = scip.decode(allocator, tmp_data) catch |err| {
        allocator.free(tmp_data);
        return err;
    };

    return .{ .index = index, .backing_data = tmp_data };
}

/// Merge a document into the master index (replace existing or append).
fn mergeDocument(allocator: std.mem.Allocator, index: *scip.Index, new_doc: scip.Document) void {
    // Look for existing document with same relative_path
    for (index.documents, 0..) |*doc, i| {
        if (std.mem.eql(u8, doc.relative_path, new_doc.relative_path)) {
            // Replace: free old internals, put new doc in place
            scip.freeDocument(allocator, doc);
            index.documents[i] = new_doc;
            return;
        }
    }

    // Not found — grow documents slice and append
    const old_len = index.documents.len;
    const new_docs = allocator.alloc(scip.Document, old_len + 1) catch return;
    @memcpy(new_docs[0..old_len], index.documents);
    new_docs[old_len] = new_doc;
    if (old_len > 0) allocator.free(index.documents);
    index.documents = new_docs;
}

/// Remove a document from the index by relative_path.
fn removeDocument(allocator: std.mem.Allocator, index: *scip.Index, rel_path: []const u8) void {
    for (index.documents, 0..) |*doc, i| {
        if (std.mem.eql(u8, doc.relative_path, rel_path)) {
            scip.freeDocument(allocator, doc);
            // Swap-remove
            const last = index.documents.len - 1;
            if (i != last) {
                index.documents[i] = index.documents[last];
            }
            // Shrink
            const new_docs = allocator.alloc(scip.Document, last) catch return;
            @memcpy(new_docs, index.documents[0..last]);
            allocator.free(index.documents);
            index.documents = new_docs;
            return;
        }
    }
}

/// Re-index a single file and update the master index.
fn reindexFile(allocator: std.mem.Allocator, file_path: []const u8) bool {
    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);

    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    const ext_str = std.fs.path.extension(file_path);
    if (ext_str.len == 0) return false;

    // Try tree-sitter first
    if (tree_sitter_indexer.detectLanguage(ext_str)) |lang| {
        const source = readFileContents(allocator, file_path) orelse return false;
        defer allocator.free(source);

        var indexer = tree_sitter_indexer.Indexer.init();
        defer indexer.deinit();

        const result = indexer.indexFile(allocator, source, file_path, lang) catch return false;
        defer allocator.free(result.string_data);
        mergeDocument(allocator, &master_index, result.doc);
    } else {
        // Fall back to external indexer
        const extension = extensions.resolveByExtension(allocator, ext_str) orelse return false;

        const file_result = invokeIndexerForFile(allocator, file_path, &extension) catch return false;
        defer allocator.free(file_result.backing_data);
        mergeDocument(allocator, &master_index, file_result.doc);
    }

    // Encode and write
    const encoded = scip_encode.encodeIndex(allocator, master_index) catch return false;
    defer allocator.free(encoded);

    const out_file = std.fs.createFileAbsolute(index_path, .{}) catch return false;
    defer out_file.close();
    out_file.writeAll(encoded) catch return false;
    return true;
}

/// Write and save an index to disk.
fn saveIndex(allocator: std.mem.Allocator, index: scip.Index, index_path: []const u8) bool {
    const encoded = scip_encode.encodeIndex(allocator, index) catch return false;
    defer allocator.free(encoded);

    const out_file = std.fs.createFileAbsolute(index_path, .{}) catch return false;
    defer out_file.close();
    out_file.writeAll(encoded) catch return false;
    return true;
}

fn runExternalTool(allocator: std.mem.Allocator, cfg: settings_mod.ToolConfig, subs: []const settings_mod.Substitution) !void {
    const sub_args = settings_mod.substituteArgs(allocator, cfg.args, subs) catch {
        printErr("error: failed to substitute tool args\n");
        return error.Explained;
    };
    defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

    const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
    defer allocator.free(full_args);
    full_args[0] = cfg.command;
    @memcpy(full_args[1..], sub_args);

    var child = std.process.Child.init(full_args, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    if (term.Exited != 0) {
        printErr("error: external tool exited with non-zero status\n");
        return error.Explained;
    }
}

// ── code/edit ───────────────────────────────────────────────────────────

fn codeEdit(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_edit);
        return;
    }

    if (args.len == 0) {
        printErr("error: file path is required\nRun " ++ dim ++ "cog code/edit --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    }

    const file_path: []const u8 = args[0];
    const old_text: []const u8 = findFlag(args[1..], "--old") orelse {
        printErr("error: --old flag is required\nRun " ++ dim ++ "cog code/edit --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    };
    const new_text: []const u8 = findFlag(args[1..], "--new") orelse {
        printErr("error: --new flag is required\nRun " ++ dim ++ "cog code/edit --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    };

    // Load settings for external editor
    const settings = settings_mod.Settings.load(allocator);
    defer if (settings) |s| s.deinit(allocator);

    const use_external_editor = if (settings) |s| s.editor != null else false;

    if (use_external_editor) {
        const editor_cfg = settings.?.editor.?;
        const subs: []const settings_mod.Substitution = &.{
            .{ .key = "{file}", .value = file_path },
            .{ .key = "{old}", .value = old_text },
            .{ .key = "{new}", .value = new_text },
        };
        const sub_args = settings_mod.substituteArgs(allocator, editor_cfg.args, subs) catch {
            printErr("error: failed to substitute editor args\n");
            return error.Explained;
        };
        defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

        const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
        defer allocator.free(full_args);
        full_args[0] = editor_cfg.command;
        @memcpy(full_args[1..], sub_args);

        var child = std.process.Child.init(full_args, allocator);
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();

        if (term.Exited != 0) {
            printErr("error: editor exited with non-zero status\n");
            return error.Explained;
        }
    } else {
        // Built-in string replacement
        try builtinEdit(allocator, file_path, old_text, new_text);
    }

    // Re-index the edited file
    const reindexed = reindexFile(allocator, file_path);
    if (!reindexed) {
        printErr("warning: re-index failed, index may be stale\n");
    }

    // Output JSON
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("file");
    try s.write(file_path);
    try s.objectField("edited");
    try s.write(true);
    try s.objectField("reindexed");
    try s.write(reindexed);
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn builtinEdit(allocator: std.mem.Allocator, file_path: []const u8, old_text: []const u8, new_text: []const u8) !void {
    // Read file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        printErr("error: file not found: ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch {
        printErr("error: failed to read file\n");
        return error.Explained;
    };
    defer allocator.free(content);

    // Find old_text — check for ambiguity
    const first_pos = std.mem.indexOf(u8, content, old_text) orelse {
        printErr("error: old text not found in ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };

    // Check for second occurrence
    if (first_pos + old_text.len < content.len) {
        if (std.mem.indexOf(u8, content[first_pos + old_text.len ..], old_text)) |_| {
            // Count total occurrences
            var count: usize = 0;
            var pos: usize = 0;
            while (pos < content.len) {
                if (std.mem.indexOf(u8, content[pos..], old_text)) |idx| {
                    count += 1;
                    pos = pos + idx + old_text.len;
                } else break;
            }
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "error: old text is ambiguous (found {d} occurrences) — provide more context\n", .{count}) catch "error: old text is ambiguous\n";
            printErr(count_str);
            return error.Explained;
        }
    }

    // Build new content
    const new_len = content.len - old_text.len + new_text.len;
    const new_content = allocator.alloc(u8, new_len) catch {
        printErr("error: out of memory\n");
        return error.Explained;
    };
    defer allocator.free(new_content);

    @memcpy(new_content[0..first_pos], content[0..first_pos]);
    @memcpy(new_content[first_pos..][0..new_text.len], new_text);
    const after_old = first_pos + old_text.len;
    @memcpy(new_content[first_pos + new_text.len ..], content[after_old..]);

    // Write back
    const out_file = std.fs.cwd().createFile(file_path, .{}) catch {
        printErr("error: failed to write file\n");
        return error.Explained;
    };
    defer out_file.close();
    out_file.writeAll(new_content) catch {
        printErr("error: failed to write file\n");
        return error.Explained;
    };
}

// ── code/query ──────────────────────────────────────────────────────────

fn codeQuery(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_query);
        return;
    }

    // Determine query mode: exactly one of --find, --refs, --symbols, --structure
    const find_name = findFlag(args, "--find");
    const refs_name = findFlag(args, "--refs");
    const symbols_file = findFlag(args, "--symbols");
    const is_structure = hasFlag(args, "--structure");

    const mode_count = @as(usize, if (find_name != null) 1 else 0) +
        @as(usize, if (refs_name != null) 1 else 0) +
        @as(usize, if (symbols_file != null) 1 else 0) +
        @as(usize, if (is_structure) 1 else 0);

    if (mode_count == 0) {
        printErr("error: specify one of --find, --refs, --symbols, or --structure\nRun " ++ dim ++ "cog code/query --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    }
    if (mode_count > 1) {
        printErr("error: specify only one of --find, --refs, --symbols, or --structure\n");
        return error.Explained;
    }

    if (find_name) |name| return queryFind(allocator, args, name);
    if (refs_name) |name| return queryRefs(allocator, args, name);
    if (symbols_file) |file_path| return querySymbols(allocator, args, file_path);
    if (is_structure) return queryStructure(allocator);
}

fn queryFind(allocator: std.mem.Allocator, args: []const [:0]const u8, name: []const u8) !void {
    const kind_filter: ?[]const u8 = if (findFlag(args, "--kind")) |k| @as([]const u8, k) else null;
    const limit_str = findFlag(args, "--limit");
    const limit: usize = if (limit_str) |l|
        std.fmt.parseInt(usize, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        }
    else
        1;

    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    const matches = ci.findSymbol(name, kind_filter);
    if (matches.len == 0) {
        printErr("error: no symbol found matching '");
        printErr(name);
        printErr("'\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    if (limit == 1) {
        // Single result (backward compatible)
        const match = matches.items[0];
        try s.beginObject();
        try s.objectField("symbol");
        try s.write(match.symbol);
        try s.objectField("path");
        try s.write(match.def.path);
        try s.objectField("line");
        try s.write(match.def.line);
        try s.objectField("kind");
        try s.write(scip.kindName(match.def.kind));
        if (match.def.display_name.len > 0) {
            try s.objectField("display_name");
            try s.write(match.def.display_name);
        }
        if (match.def.documentation.len > 0) {
            try s.objectField("documentation");
            try s.write(match.def.documentation[0]);
        }
        try s.endObject();
    } else {
        // Multiple results as array
        try s.beginArray();
        const count = @min(matches.len, limit);
        for (matches.items[0..count]) |match| {
            try s.beginObject();
            try s.objectField("symbol");
            try s.write(match.symbol);
            try s.objectField("path");
            try s.write(match.def.path);
            try s.objectField("line");
            try s.write(match.def.line);
            try s.objectField("kind");
            try s.write(scip.kindName(match.def.kind));
            if (match.def.display_name.len > 0) {
                try s.objectField("display_name");
                try s.write(match.def.display_name);
            }
            if (match.def.documentation.len > 0) {
                try s.objectField("documentation");
                try s.write(match.def.documentation[0]);
            }
            try s.endObject();
        }
        try s.endArray();
    }

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn queryRefs(allocator: std.mem.Allocator, args: []const [:0]const u8, name: []const u8) !void {
    const kind_filter: ?[]const u8 = if (findFlag(args, "--kind")) |k| @as([]const u8, k) else null;
    const limit_str = findFlag(args, "--limit");
    const limit: usize = if (limit_str) |l|
        std.fmt.parseInt(usize, l, 10) catch {
            printErr("error: --limit must be a number\n");
            return error.Explained;
        }
    else
        100;

    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    const matches = ci.findSymbol(name, kind_filter);
    if (matches.len == 0) {
        printErr("error: no symbol found matching '");
        printErr(name);
        printErr("'\n");
        return error.Explained;
    }

    const match = matches.items[0];
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("symbol");
    try s.write(match.symbol);
    try s.objectField("definition");
    try s.beginObject();
    try s.objectField("path");
    try s.write(match.def.path);
    try s.objectField("line");
    try s.write(match.def.line);
    try s.endObject();
    try s.objectField("references");
    try s.beginArray();

    if (ci.symbol_to_refs.get(match.symbol)) |refs| {
        const count = @min(refs.items.len, limit);
        for (refs.items[0..count]) |ref| {
            try s.beginObject();
            try s.objectField("path");
            try s.write(ref.path);
            try s.objectField("line");
            try s.write(ref.line);
            try s.objectField("roles");
            try s.write(ref.roles);
            try s.endObject();
        }
    }

    try s.endArray();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn querySymbols(allocator: std.mem.Allocator, args: []const [:0]const u8, file_path: []const u8) !void {
    const kind_filter: ?[]const u8 = if (findFlag(args, "--kind")) |k| @as([]const u8, k) else null;

    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    // Try exact match first
    var doc_idx_opt = ci.path_to_doc_idx.get(file_path);

    // If exact match fails, try suffix matching (handles absolute vs relative paths)
    if (doc_idx_opt == null) {
        var iter = ci.path_to_doc_idx.iterator();
        while (iter.next()) |entry| {
            const indexed_path = entry.key_ptr.*;
            // Check if query path ends with indexed path or vice versa
            if (std.mem.endsWith(u8, file_path, indexed_path) or
                std.mem.endsWith(u8, indexed_path, file_path)) {
                doc_idx_opt = entry.value_ptr.*;
                break;
            }
        }
    }

    const doc_idx = doc_idx_opt orelse {
        printErr("error: file not found in index: ");
        printErr(file_path);
        printErr("\n\nIndexed paths:\n");
        var iter = ci.path_to_doc_idx.iterator();
        var shown: usize = 0;
        while (iter.next()) |entry| : (shown += 1) {
            if (shown >= 10) {
                printErr("  ... and ");
                var count_buf: [32]u8 = undefined;
                const remaining = ci.path_to_doc_idx.count() - 10;
                const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{remaining}) catch "more";
                printErr(count_str);
                printErr(" more files\n");
                break;
            }
            printErr("  ");
            printErr(entry.key_ptr.*);
            printErr("\n");
        }
        return error.Explained;
    };
    const doc = ci.index.documents[doc_idx];

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("path");
    try s.write(doc.relative_path);
    try s.objectField("symbols");
    try s.beginArray();

    for (doc.symbols) |sym| {
        const k = scip.kindName(sym.kind);
        if (kind_filter) |kf| {
            if (!std.ascii.eqlIgnoreCase(k, kf)) continue;
        }

        var def_line: i32 = 0;
        for (doc.occurrences) |occ| {
            if (std.mem.eql(u8, occ.symbol, sym.symbol) and scip.SymbolRole.isDefinition(occ.symbol_roles)) {
                def_line = occ.range.start_line;
                break;
            }
        }

        try s.beginObject();
        const display = if (sym.display_name.len > 0)
            sym.display_name
        else
            scip.extractSymbolName(sym.symbol);
        try s.objectField("name");
        try s.write(display);
        try s.objectField("kind");
        try s.write(k);
        try s.objectField("line");
        try s.write(def_line);
        if (sym.documentation.len > 0) {
            try s.objectField("documentation");
            const doc_str = sym.documentation[0];
            if (doc_str.len > 200) {
                try s.write(doc_str[0..200]);
            } else {
                try s.write(doc_str);
            }
        }
        try s.endObject();
    }

    try s.endArray();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn queryStructure(allocator: std.mem.Allocator) !void {
    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("files");
    try s.beginArray();

    for (ci.index.documents) |doc| {
        try s.beginObject();
        try s.objectField("path");
        try s.write(doc.relative_path);
        if (doc.language.len > 0) {
            try s.objectField("language");
            try s.write(doc.language);
        }
        try s.objectField("symbols");
        try s.beginArray();

        for (doc.symbols) |sym| {
            var def_line: i32 = 0;
            for (doc.occurrences) |occ| {
                if (std.mem.eql(u8, occ.symbol, sym.symbol) and scip.SymbolRole.isDefinition(occ.symbol_roles)) {
                    def_line = occ.range.start_line;
                    break;
                }
            }

            const display = if (sym.display_name.len > 0)
                sym.display_name
            else
                scip.extractSymbolName(sym.symbol);

            try s.beginObject();
            try s.objectField("name");
            try s.write(display);
            try s.objectField("kind");
            try s.write(scip.kindName(sym.kind));
            try s.objectField("line");
            try s.write(def_line);
            try s.endObject();
        }

        try s.endArray();
        try s.endObject();
    }

    try s.endArray();
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

// ── code/create ─────────────────────────────────────────────────────────

fn codeCreate(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_create);
        return;
    }

    if (args.len == 0) {
        printErr("error: file path is required\nRun " ++ dim ++ "cog code/create --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    }

    const file_path: []const u8 = args[0];
    const content: []const u8 = findFlag(args[1..], "--content") orelse "";

    // Load settings for external creator
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    if (s) |ss| {
        if (ss.creator) |cfg| {
            const subs: []const settings_mod.Substitution = &.{
                .{ .key = "{file}", .value = file_path },
                .{ .key = "{content}", .value = content },
            };
            try runExternalTool(allocator, cfg, subs);
        } else {
            try builtinCreate(file_path, content);
        }
    } else {
        try builtinCreate(file_path, content);
    }

    // Index the new file
    const reindexed = reindexFile(allocator, file_path);

    // Output JSON
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("created");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn builtinCreate(file_path: []const u8, content: []const u8) !void {
    // Create parent directories if needed
    if (std.fs.path.dirname(file_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {
            printErr("error: failed to create parent directories\n");
            return error.Explained;
        };
    }

    const file = std.fs.cwd().createFile(file_path, .{ .exclusive = true }) catch {
        printErr("error: file already exists: ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };
    defer file.close();

    if (content.len > 0) {
        file.writeAll(content) catch {
            printErr("error: failed to write file content\n");
            return error.Explained;
        };
    }
}

// ── code/delete ─────────────────────────────────────────────────────────

fn codeDelete(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_delete);
        return;
    }

    if (args.len == 0) {
        printErr("error: file path is required\nRun " ++ dim ++ "cog code/delete --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    }

    const file_path: []const u8 = args[0];

    // Load settings for external deleter
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    if (s) |ss| {
        if (ss.deleter) |cfg| {
            const subs: []const settings_mod.Substitution = &.{
                .{ .key = "{file}", .value = file_path },
            };
            try runExternalTool(allocator, cfg, subs);
        } else {
            try builtinDelete(file_path);
        }
    } else {
        try builtinDelete(file_path);
    }

    // Remove from index
    const removed = removeFromIndex(allocator, file_path);

    // Output JSON
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("deleted");
    try st.write(true);
    try st.objectField("index_updated");
    try st.write(removed);
    try st.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn builtinDelete(file_path: []const u8) !void {
    std.fs.cwd().deleteFile(file_path) catch {
        printErr("error: failed to delete file: ");
        printErr(file_path);
        printErr("\n");
        return error.Explained;
    };
}

/// Remove a file's document from the index and save.
fn removeFromIndex(allocator: std.mem.Allocator, file_path: []const u8) bool {
    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);

    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    removeDocument(allocator, &master_index, file_path);
    return saveIndex(allocator, master_index, index_path);
}

// ── code/rename ─────────────────────────────────────────────────────────

fn codeRename(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_rename);
        return;
    }

    if (args.len == 0) {
        printErr("error: old file path is required\nRun " ++ dim ++ "cog code/rename --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    }

    const old_path: []const u8 = args[0];
    const new_path: []const u8 = findFlag(args[1..], "--to") orelse {
        printErr("error: --to flag is required\nRun " ++ dim ++ "cog code/rename --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    };

    // Load settings for external renamer
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    if (s) |ss| {
        if (ss.renamer) |cfg| {
            const subs: []const settings_mod.Substitution = &.{
                .{ .key = "{old}", .value = old_path },
                .{ .key = "{new}", .value = new_path },
            };
            try runExternalTool(allocator, cfg, subs);
        } else {
            try builtinRename(old_path, new_path);
        }
    } else {
        try builtinRename(old_path, new_path);
    }

    // Update index: remove old document, index new file
    const cog_dir = paths.findCogDir(allocator) catch {
        // Output without index update
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var st: Stringify = .{ .writer = &aw.writer };
        try st.beginObject();
        try st.objectField("old");
        try st.write(old_path);
        try st.objectField("new");
        try st.write(new_path);
        try st.objectField("renamed");
        try st.write(true);
        try st.objectField("reindexed");
        try st.write(false);
        try st.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        printStdout(result);
        return;
    };
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    removeDocument(allocator, &master_index, old_path);

    // Try to index the new path
    var reindexed = false;
    var reindex_backing: ?[]const u8 = null;
    var reindex_string_data: ?[]const u8 = null;
    defer if (reindex_backing) |data| allocator.free(data);
    defer if (reindex_string_data) |data| allocator.free(data);
    const ext_str = std.fs.path.extension(new_path);
    if (ext_str.len > 0) {
        if (tree_sitter_indexer.detectLanguage(ext_str)) |lang| {
            if (readFileContents(allocator, new_path)) |source| {
                defer allocator.free(source);
                var indexer = tree_sitter_indexer.Indexer.init();
                defer indexer.deinit();
                if (indexer.indexFile(allocator, source, new_path, lang)) |result| {
                    reindex_string_data = result.string_data;
                    mergeDocument(allocator, &master_index, result.doc);
                    reindexed = true;
                } else |_| {}
            }
        } else if (extensions.resolveByExtension(allocator, ext_str)) |extension| {
            if (invokeIndexerForFile(allocator, new_path, &extension)) |file_result| {
                reindex_backing = file_result.backing_data;
                mergeDocument(allocator, &master_index, file_result.doc);
                reindexed = true;
            } else |_| {}
        }
    }

    _ = saveIndex(allocator, master_index, index_path);

    // Output JSON
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("old");
    try st.write(old_path);
    try st.objectField("new");
    try st.write(new_path);
    try st.objectField("renamed");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn builtinRename(old_path: []const u8, new_path: []const u8) !void {
    // Create parent directories for new path if needed
    if (std.fs.path.dirname(new_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    std.fs.cwd().rename(old_path, new_path) catch {
        printErr("error: failed to rename ");
        printErr(old_path);
        printErr(" to ");
        printErr(new_path);
        printErr("\n");
        return error.Explained;
    };
}

// ── code/status ─────────────────────────────────────────────────────────

fn codeStatus(allocator: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (hasFlag(args, "--help")) {
        printCommandHelp(help.code_status);
        return;
    }

    const index_path = getIndexPath(allocator) catch return;
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch {
        // No index exists
        var aw: Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var s: Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("exists");
        try s.write(false);
        try s.endObject();
        const result = try aw.toOwnedSlice();
        defer allocator.free(result);
        printStdout(result);
        return;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch {
        printErr("error: failed to read index file\n");
        return error.Explained;
    };
    defer allocator.free(data);

    var index = scip.decode(allocator, data) catch {
        printErr("error: corrupt index file\n");
        return error.Explained;
    };
    defer scip.freeIndex(allocator, &index);

    var total_symbols: usize = 0;
    for (index.documents) |doc| {
        total_symbols += doc.symbols.len;
    }
    total_symbols += index.external_symbols.len;

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("exists");
    try s.write(true);
    try s.objectField("path");
    try s.write(index_path);
    try s.objectField("documents");
    try s.write(index.documents.len);
    try s.objectField("symbols");
    try s.write(total_symbols);
    if (index.metadata.tool_info.name.len > 0) {
        try s.objectField("indexer");
        try s.write(index.metadata.tool_info.name);
    }
    if (index.metadata.project_root.len > 0) {
        try s.objectField("project_root");
        try s.write(index.metadata.project_root);
    }
    try s.endObject();
    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "CodeIndex.build and findSymbol" {
    const allocator = std.testing.allocator;

    // Construct an Index programmatically
    var occurrences = try allocator.alloc(scip.Occurrence, 2);
    defer allocator.free(occurrences);
    occurrences[0] = .{
        .range = .{ .start_line = 10, .start_char = 0, .end_line = 10, .end_char = 5 },
        .symbol = "pkg/Foo#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occurrences[1] = .{
        .range = .{ .start_line = 15, .start_char = 4, .end_line = 15, .end_char = 10 },
        .symbol = "pkg/Foo#bar().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    var doc_symbols = try allocator.alloc(scip.SymbolInformation, 2);
    defer allocator.free(doc_symbols);
    doc_symbols[0] = .{
        .symbol = "pkg/Foo#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49, // struct
        .display_name = "Foo",
        .enclosing_symbol = "",
    };
    doc_symbols[1] = .{
        .symbol = "pkg/Foo#bar().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 26, // method
        .display_name = "bar",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 1);
    documents[0] = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = occurrences,
        .symbols = doc_symbols,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "scip-go", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    var ci = try CodeIndex.build(allocator, index);
    defer {
        ci.symbol_to_defs.deinit(allocator);
        var ref_iter = ci.symbol_to_refs.iterator();
        while (ref_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        ci.symbol_to_refs.deinit(allocator);
        ci.path_to_doc_idx.deinit(allocator);
        allocator.free(ci.index.documents);
    }

    // Test findSymbol
    const matches = ci.findSymbol("Foo", null);
    try std.testing.expect(matches.len > 0);
    try std.testing.expectEqualStrings("pkg/Foo#", matches.items[0].symbol);
    try std.testing.expectEqual(@as(i32, 10), matches.items[0].def.line);

    // Test findSymbol with kind filter
    const method_matches = ci.findSymbol("bar", "method");
    try std.testing.expect(method_matches.len > 0);

    const struct_matches = ci.findSymbol("bar", "struct");
    try std.testing.expectEqual(@as(usize, 0), struct_matches.len);

    // Test path_to_doc_idx
    try std.testing.expect(ci.path_to_doc_idx.get("pkg/foo.go") != null);
    try std.testing.expect(ci.path_to_doc_idx.get("nonexistent.go") == null);
}

test "mergeDocument replaces existing document" {
    const allocator = std.testing.allocator;

    // Create initial index with one document
    var docs = try allocator.alloc(scip.Document, 1);
    docs[0] = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = &.{},
        .symbols = &.{},
    };

    var index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = docs,
        .external_symbols = &.{},
    };
    defer allocator.free(index.documents);

    // Merge a replacement document with same path
    const new_doc: scip.Document = .{
        .language = "go",
        .relative_path = "pkg/foo.go",
        .occurrences = &.{},
        .symbols = &.{},
    };
    mergeDocument(allocator, &index, new_doc);

    try std.testing.expectEqual(@as(usize, 1), index.documents.len);
    try std.testing.expectEqualStrings("pkg/foo.go", index.documents[0].relative_path);

    // Merge a new document with different path
    const another_doc: scip.Document = .{
        .language = "go",
        .relative_path = "pkg/bar.go",
        .occurrences = &.{},
        .symbols = &.{},
    };
    mergeDocument(allocator, &index, another_doc);

    try std.testing.expectEqual(@as(usize, 2), index.documents.len);
}

test "globMatch literal paths" {
    try std.testing.expect(globMatch("src/foo.ts", "src/foo.ts"));
    try std.testing.expect(!globMatch("src/foo.ts", "src/bar.ts"));
    try std.testing.expect(!globMatch("src/foo.ts", "src/foo.tsx"));
}

test "globMatch single star" {
    try std.testing.expect(globMatch("*.ts", "foo.ts"));
    try std.testing.expect(globMatch("*.ts", "bar.ts"));
    try std.testing.expect(!globMatch("*.ts", "foo.js"));
    try std.testing.expect(!globMatch("*.ts", "src/foo.ts")); // * does not cross /
    try std.testing.expect(globMatch("src/*.go", "src/main.go"));
    try std.testing.expect(!globMatch("src/*.go", "src/sub/main.go"));
}

test "globMatch double star" {
    try std.testing.expect(globMatch("**/*.ts", "foo.ts"));
    try std.testing.expect(globMatch("**/*.ts", "src/foo.ts"));
    try std.testing.expect(globMatch("**/*.ts", "src/sub/foo.ts"));
    try std.testing.expect(!globMatch("**/*.ts", "foo.js"));
    try std.testing.expect(globMatch("src/**/*.go", "src/main.go"));
    try std.testing.expect(globMatch("src/**/*.go", "src/pkg/main.go"));
    try std.testing.expect(globMatch("src/**/*.go", "src/pkg/sub/main.go"));
    try std.testing.expect(!globMatch("src/**/*.go", "lib/main.go"));
}

test "globMatch question mark" {
    try std.testing.expect(globMatch("?.ts", "a.ts"));
    try std.testing.expect(!globMatch("?.ts", "ab.ts"));
    try std.testing.expect(!globMatch("?.ts", "/.ts")); // ? does not match /
    try std.testing.expect(globMatch("src/?.go", "src/a.go"));
}

test "globMatch catch-all" {
    try std.testing.expect(globMatch("**/*", "foo.ts"));
    try std.testing.expect(globMatch("**/*", "src/foo.ts"));
    try std.testing.expect(globMatch("**/*", "src/sub/foo.ts"));
}

test "globPrefix extracts literal directory" {
    try std.testing.expectEqualStrings("src", globPrefix("src/**/*.ts"));
    try std.testing.expectEqualStrings(".", globPrefix("**/*.go"));
    try std.testing.expectEqualStrings("src", globPrefix("src/*.py"));
    try std.testing.expectEqualStrings(".", globPrefix("*.py"));
    try std.testing.expectEqualStrings("src", globPrefix("src/foo.ts")); // no wildcard, but prefix is src
}

test "pathIsTest" {
    try std.testing.expect(CodeIndex.pathIsTest("src/__tests__/foo.js"));
    try std.testing.expect(CodeIndex.pathIsTest("src/test/main.go"));
    try std.testing.expect(CodeIndex.pathIsTest("lib/foo.test.ts"));
    try std.testing.expect(CodeIndex.pathIsTest("lib/foo.spec.js"));
    try std.testing.expect(CodeIndex.pathIsTest("main_test.go"));
    try std.testing.expect(!CodeIndex.pathIsTest("src/main.go"));
    try std.testing.expect(!CodeIndex.pathIsTest("lib/component.js"));
}

test "countPathSeparators" {
    try std.testing.expectEqual(@as(usize, 0), CodeIndex.countPathSeparators("main.go"));
    try std.testing.expectEqual(@as(usize, 1), CodeIndex.countPathSeparators("src/main.go"));
    try std.testing.expectEqual(@as(usize, 2), CodeIndex.countPathSeparators("src/pkg/main.go"));
    try std.testing.expectEqual(@as(usize, 3), CodeIndex.countPathSeparators("a/b/c/d.go"));
}

test "sortMatchesByScore" {
    var matches: CodeIndex.MatchList = .{};
    matches.items[0] = .{ .symbol = "a", .def = .{ .path = "a.go", .line = 0, .kind = 0, .display_name = "a", .documentation = &.{} }, .score = 10 };
    matches.items[1] = .{ .symbol = "b", .def = .{ .path = "b.go", .line = 0, .kind = 0, .display_name = "b", .documentation = &.{} }, .score = 50 };
    matches.items[2] = .{ .symbol = "c", .def = .{ .path = "c.go", .line = 0, .kind = 0, .display_name = "c", .documentation = &.{} }, .score = 30 };
    matches.len = 3;

    CodeIndex.sortMatchesByScore(&matches);

    try std.testing.expectEqual(@as(u8, 50), matches.items[0].score);
    try std.testing.expectEqual(@as(u8, 30), matches.items[1].score);
    try std.testing.expectEqual(@as(u8, 10), matches.items[2].score);
}
