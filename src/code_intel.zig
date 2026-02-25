const std = @import("std");
const json = std.json;
const Stringify = json.Stringify;
const Writer = std.io.Writer;
const posix = std.posix;
const scip = @import("scip.zig");
const scip_encode = @import("scip_encode.zig");
const protobuf = @import("protobuf.zig");
const help = @import("help_text.zig");
const tui = @import("tui.zig");
const settings_mod = @import("settings.zig");
const paths = @import("paths.zig");
const extensions = @import("extensions.zig");
const tree_sitter_indexer = @import("tree_sitter_indexer.zig");

// Advisory file locking via flock(2). Auto-released on close/process exit.
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
const LOCK_EX: c_int = 2;
const LOCK_UN: c_int = 8;

/// Acquire an exclusive advisory lock on .cog/index.lock.
/// Blocks until the lock is acquired. Returns the lock fd, or null on failure.
fn acquireIndexLock(allocator: std.mem.Allocator, cog_dir: []const u8) ?posix.fd_t {
    const lock_path = std.fmt.allocPrint(allocator, "{s}/index.lock", .{cog_dir}) catch return null;
    defer allocator.free(lock_path);
    const lock_path_z = posix.toPosixPath(lock_path) catch return null;
    const fd = posix.open(&lock_path_z, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644) catch return null;
    if (flock(fd, LOCK_EX) != 0) {
        posix.close(fd);
        return null;
    }
    return fd;
}

/// Release the advisory lock and close the fd.
fn releaseIndexLock(fd: posix.fd_t) void {
    _ = flock(fd, LOCK_UN);
    posix.close(fd);
}

// ANSI styles
const cyan = "\x1B[36m";
const bold = "\x1B[1m";
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
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn printCommandHelp(comptime help_text: []const u8) void {
    tui.header();
    printErr(help_text);
}

pub fn builtinExtensionList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (extensions.builtins) |b| {
            out = out ++ "    " ++ bold ++ b.name ++ reset ++ dim;
            for (b.file_extensions) |ext| {
                out = out ++ " " ++ ext;
            }
            out = out ++ reset ++ "\n";
        }
        return out;
    }
}

pub fn listInstalledBlock(allocator: std.mem.Allocator) ?[]const u8 {
    return listInstalledBlockFiltered(allocator, false);
}

pub fn listInstalledDebugBlock(allocator: std.mem.Allocator) ?[]const u8 {
    return listInstalledBlockFiltered(allocator, true);
}

fn listInstalledBlockFiltered(allocator: std.mem.Allocator, debug_only: bool) ?[]const u8 {
    const installed = extensions.listInstalled(allocator) catch return null;
    defer extensions.freeInstalledList(allocator, installed);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    var count: usize = 0;
    for (installed) |ext| {
        if (debug_only and !ext.has_debugger) continue;
        if (count == 0) {
            w.writeAll(cyan ++ bold ++ "  Installed" ++ reset ++ "\n") catch return null;
        }
        w.writeAll("    " ++ bold) catch return null;
        w.writeAll(ext.name) catch return null;
        w.writeAll(reset ++ dim) catch return null;
        for (ext.file_extensions) |fe| {
            w.writeAll(" ") catch return null;
            w.writeAll(fe) catch return null;
        }
        w.writeAll(reset ++ "\n") catch return null;
        count += 1;
    }
    if (count == 0) return null;
    w.writeAll("\n") catch return null;
    return buf.toOwnedSlice(allocator) catch return null;
}

pub fn builtinDebugExtensionList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (extensions.builtins) |b| {
            if (b.debug == null) continue;
            out = out ++ "    " ++ bold ++ b.name ++ reset ++ dim;
            for (b.file_extensions) |ext| {
                out = out ++ " " ++ ext;
            }
            out = out ++ reset ++ "\n";
        }
        return out;
    }
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
        printErr("error: no .cog directory found. Run " ++ dim ++ "cog code:index" ++ reset ++ " first.\n");
        return error.Explained;
    };
    defer allocator.free(cog_dir);
    return std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
}

// ── CodeIndex ───────────────────────────────────────────────────────────

const DefInfo = struct {
    path: []const u8,
    line: i32,
    end_line: i32 = 0, // end of definition body (from enclosing_range); 0 = unknown
    kind: i32,
    display_name: []const u8,
    documentation: []const []const u8,
};

const RefInfo = struct {
    path: []const u8,
    line: i32,
    roles: []const u8,
};

pub const CodeIndex = struct {
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
                    // Find the definition occurrence for this symbol
                    var def_line: i32 = 0;
                    var def_end_line: i32 = 0;
                    for (doc.occurrences) |occ| {
                        if (std.mem.eql(u8, occ.symbol, sym.symbol) and scip.SymbolRole.isDefinition(occ.symbol_roles)) {
                            def_line = occ.range.start_line;
                            if (occ.enclosing_range) |er| {
                                def_end_line = er.end_line;
                            }
                            break;
                        }
                    }
                    try symbol_to_defs.put(allocator, sym.symbol, .{
                        .path = doc.relative_path,
                        .line = def_line,
                        .end_line = def_end_line,
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

    pub fn deinit(self: *CodeIndex, allocator: std.mem.Allocator) void {
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
    /// Supports glob patterns (* and ?) when the name contains wildcard characters.
    /// When file_filter is set, only symbols in matching files are returned.
    /// Caller must call `matches.deinit(allocator)` when done.
    fn findSymbol(self: *const CodeIndex, allocator: std.mem.Allocator, name: []const u8, kind_filter: ?[]const u8, file_filter: ?[]const u8) !MatchList {
        const is_glob = hasGlobChars(name);
        var matches: MatchList = .empty;
        var iter = self.symbol_to_defs.iterator();
        while (iter.next()) |entry| {
            const sym_name = entry.key_ptr.*;
            const def = entry.value_ptr.*;

            // Match against display_name
            const display_match = if (is_glob)
                (def.display_name.len > 0 and nameGlobMatch(name, def.display_name))
            else
                (def.display_name.len > 0 and std.ascii.eqlIgnoreCase(def.display_name, name));

            // Match against extracted name from symbol string
            const extracted = scip.extractSymbolName(sym_name);
            const extracted_match = if (is_glob)
                nameGlobMatch(name, extracted)
            else
                std.ascii.eqlIgnoreCase(extracted, name);

            if (display_match or extracted_match) {
                // Apply kind filter
                if (kind_filter) |kf| {
                    const k = scip.kindName(def.kind);
                    if (!std.ascii.eqlIgnoreCase(k, kf)) continue;
                }

                // Apply file filter
                if (file_filter) |ff| {
                    if (!fileMatchesSuffix(def.path, ff)) continue;
                }

                // Calculate relevance score
                var score: u8 = 0;

                if (is_glob) {
                    // For glob matches, award points for short-name match
                    score += 80;
                } else {
                    // Exact case-sensitive match (highest priority)
                    if (std.mem.eql(u8, def.display_name, name) or std.mem.eql(u8, extracted, name)) {
                        score += 100;
                    }
                }

                // Not in a test file
                if (!pathIsTest(def.path)) {
                    score += 50;
                }

                // Shorter paths (less nested) rank higher
                const path_depth = countPathSeparators(def.path);
                if (path_depth <= 2) score += 10;

                try matches.append(allocator, .{ .symbol = sym_name, .def = def, .score = score });
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
        if (matches.items.len <= 1) return;

        var i: usize = 1;
        while (i < matches.items.len) : (i += 1) {
            const key = matches.items[i];
            var j: usize = i;
            while (j > 0 and matches.items[j - 1].score < key.score) : (j -= 1) {
                matches.items[j] = matches.items[j - 1];
            }
            matches.items[j] = key;
        }
    }

    const MatchEntry = struct { symbol: []const u8, def: DefInfo, score: u8 = 0 };
    const MatchList = std.ArrayListUnmanaged(MatchEntry);

    /// Build a set of all symbol strings occurring in a file's document.
    /// Returns empty set if file is not in the index.
    fn buildFileOccurrenceSet(
        self: *const CodeIndex,
        allocator: std.mem.Allocator,
        file_path: []const u8,
    ) std.StringHashMapUnmanaged(void) {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return set;
        const doc = self.index.documents[doc_idx];
        for (doc.occurrences) |occ| {
            if (occ.symbol.len > 0) {
                set.put(allocator, occ.symbol, {}) catch {};
            }
        }
        return set;
    }

    /// Check if a symbol appears in a file's occurrences.
    fn isSymbolInFile(self: *const CodeIndex, file_path: []const u8, symbol: []const u8) bool {
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return false;
        const doc = self.index.documents[doc_idx];
        for (doc.occurrences) |occ| {
            if (std.mem.eql(u8, occ.symbol, symbol)) return true;
        }
        return false;
    }

    /// Find distinct symbol display names referenced within a line range of a file.
    /// Excludes the definition's own symbol. Returns non-external symbols only.
    fn findReferencesInRange(
        self: *const CodeIndex,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        own_symbol: []const u8,
        start_line: i32,
        end_line: i32,
    ) std.ArrayListUnmanaged([]const u8) {
        var result: std.ArrayListUnmanaged([]const u8) = .empty;
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return result;
        const doc = self.index.documents[doc_idx];

        // Collect unique symbols in range
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);

        for (doc.occurrences) |occ| {
            if (occ.symbol.len == 0) continue;
            // Skip self
            if (std.mem.eql(u8, occ.symbol, own_symbol)) continue;
            // Must be within range
            if (occ.range.start_line < start_line or occ.range.start_line > end_line) continue;
            // Skip if already seen
            if (seen.contains(occ.symbol)) continue;
            seen.put(allocator, occ.symbol, {}) catch continue;

            // Look up def info — skip external symbols
            const def = self.symbol_to_defs.get(occ.symbol) orelse continue;
            if (def.path.len == 0) continue;

            // Use display_name if available, else extract from symbol string
            const name = if (def.display_name.len > 0) def.display_name else scip.extractSymbolName(occ.symbol);
            if (name.len > 0) {
                result.append(allocator, name) catch continue;
            }
        }
        return result;
    }

    /// Return a table of contents for a file: all definition symbols with name, kind, line, end_line.
    /// Excludes symbols listed in `exclude_symbols`. Results sorted by line number.
    const FileTOCEntry = struct {
        name: []const u8,
        kind: i32,
        line: i32,
        end_line: i32,
    };

    /// Returns true if a SCIP kind represents a top-level definition worth showing in a TOC.
    /// Filters out parameters, local variables, fields, and other noise.
    fn isTOCKind(kind: i32) bool {
        return switch (kind) {
            7, // class
            8, // constant
            9, // constructor
            11, // enum
            12, // enum_member
            17, // function
            21, // interface
            25, // macro
            26, // method
            29, // module
            49, // struct
            53, // trait
            54, // type
            55, // type_alias
            59, // union
            => true,
            else => false,
        };
    }

    fn getFileSymbolsTOC(
        self: *const CodeIndex,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        exclude_symbols: *const std.StringHashMapUnmanaged(void),
    ) std.ArrayListUnmanaged(FileTOCEntry) {
        var result: std.ArrayListUnmanaged(FileTOCEntry) = .empty;
        const doc_idx = self.path_to_doc_idx.get(file_path) orelse return result;
        const doc = self.index.documents[doc_idx];

        for (doc.symbols) |sym| {
            if (sym.symbol.len == 0) continue;
            if (!isTOCKind(sym.kind)) continue;
            if (exclude_symbols.contains(sym.symbol)) continue;

            const def = self.symbol_to_defs.get(sym.symbol) orelse continue;
            const name = if (sym.display_name.len > 0) sym.display_name else scip.extractSymbolName(sym.symbol);
            if (name.len == 0) continue;
            // Skip test functions — real symbol names never contain spaces
            if (std.mem.indexOfScalar(u8, name, ' ') != null) continue;

            result.append(allocator, .{
                .name = name,
                .kind = sym.kind,
                .line = def.line,
                .end_line = def.end_line,
            }) catch continue;
        }

        // Sort by line number
        const SortCtx = struct {
            fn lessThan(_: void, a: FileTOCEntry, b: FileTOCEntry) bool {
                return a.line < b.line;
            }
        };
        std.mem.sortUnstable(FileTOCEntry, result.items, {}, SortCtx.lessThan);

        return result;
    }
};

// ── Batch Disambiguation ────────────────────────────────────────────────

const MAX_EXPLORE_QUERIES = 32;
const MAX_BODY_LINES: usize = 30;
const MAX_RELATED: usize = 5;
const MAX_TOTAL_BYTES: usize = 51200; // 50KB
const CONTEXT_BEFORE: usize = 3;

fn sameDirectory(path_a: []const u8, path_b: []const u8) bool {
    const dir_a = std.fs.path.dirname(path_a) orelse "";
    const dir_b = std.fs.path.dirname(path_b) orelse "";
    return std.mem.eql(u8, dir_a, dir_b);
}

/// Anchor info for disambiguation
const AnchorInfo = struct {
    query_idx: usize,
    match: CodeIndex.MatchEntry,
    file_symbols: std.StringHashMapUnmanaged(void),
};

/// Disambiguate a batch of symbol queries using anchor-driven coherence.
/// Returns an array of selected indices (one per query, null if no match).
fn disambiguateBatch(
    allocator: std.mem.Allocator,
    ci: *const CodeIndex,
    all_matches: []CodeIndex.MatchList,
) ![]?usize {
    const n = all_matches.len;
    const selected = try allocator.alloc(?usize, n);
    @memset(selected, null);

    // Phase 1: Classify anchors vs floaters
    var anchors: std.ArrayListUnmanaged(AnchorInfo) = .empty;
    defer {
        for (anchors.items) |*a| a.file_symbols.deinit(allocator);
        anchors.deinit(allocator);
    }
    var floater_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer floater_indices.deinit(allocator);

    for (all_matches, 0..) |matches, i| {
        if (matches.items.len == 0) {
            // No match — will produce error in output
            continue;
        } else if (matches.items.len == 1) {
            // Anchor: unambiguous
            selected[i] = 0;
            const anchor_match = matches.items[0];
            try anchors.append(allocator, .{
                .query_idx = i,
                .match = anchor_match,
                .file_symbols = ci.buildFileOccurrenceSet(allocator, anchor_match.def.path),
            });
        } else {
            // Floater: needs disambiguation
            try floater_indices.append(allocator, i);
        }
    }

    // Phase 2: If no floaters, all resolved
    if (floater_indices.items.len == 0) return selected;

    // Phase 3: Pair-Linking fallback if zero anchors
    if (anchors.items.len == 0) {
        // Find strongest pair across different query groups
        var best_score: i32 = -1;
        var best_qi: usize = 0;
        var best_ci_a: usize = 0;
        var best_qj: usize = 0;
        var best_ci_b: usize = 0;

        for (floater_indices.items, 0..) |fi, ii| {
            for (floater_indices.items[ii + 1 ..]) |fj| {
                for (all_matches[fi].items, 0..) |cand_a, ca| {
                    for (all_matches[fj].items, 0..) |cand_b, cb| {
                        var score: i32 = 0;
                        if (std.mem.eql(u8, cand_a.def.path, cand_b.def.path)) score += 50;
                        if (ci.isSymbolInFile(cand_a.def.path, cand_b.symbol)) score += 30;
                        if (ci.isSymbolInFile(cand_b.def.path, cand_a.symbol)) score += 30;
                        if (sameDirectory(cand_a.def.path, cand_b.def.path)) score += 10;
                        if (score > best_score) {
                            best_score = score;
                            best_qi = fi;
                            best_ci_a = ca;
                            best_qj = fj;
                            best_ci_b = cb;
                        }
                    }
                }
            }
        }

        if (best_score >= 0) {
            // Lock the pair as pseudo-anchors
            selected[best_qi] = best_ci_a;
            selected[best_qj] = best_ci_b;
            const match_a = all_matches[best_qi].items[best_ci_a];
            const match_b = all_matches[best_qj].items[best_ci_b];
            try anchors.append(allocator, .{
                .query_idx = best_qi,
                .match = match_a,
                .file_symbols = ci.buildFileOccurrenceSet(allocator, match_a.def.path),
            });
            try anchors.append(allocator, .{
                .query_idx = best_qj,
                .match = match_b,
                .file_symbols = ci.buildFileOccurrenceSet(allocator, match_b.def.path),
            });
        }
    }

    // Phase 4: Score remaining floaters against anchors
    for (floater_indices.items) |fi| {
        if (selected[fi] != null) continue; // already resolved by pair-linking

        var best_total: i32 = -1;
        var best_idx: usize = 0;

        for (all_matches[fi].items, 0..) |candidate, ci_idx| {
            var score: i32 = @intCast(candidate.score); // base score from findSymbol

            for (anchors.items) |anchor| {
                // Same file as anchor
                if (std.mem.eql(u8, candidate.def.path, anchor.match.def.path)) {
                    score += 50;
                }
                // Candidate's symbol in anchor's file occurrences
                if (anchor.file_symbols.contains(candidate.symbol)) {
                    score += 30;
                }
                // Anchor's symbol in candidate's file occurrences
                if (ci.isSymbolInFile(candidate.def.path, anchor.match.symbol)) {
                    score += 30;
                }
                // Same directory
                if (sameDirectory(candidate.def.path, anchor.match.def.path)) {
                    score += 10;
                }
            }

            if (score > best_total) {
                best_total = score;
                best_idx = ci_idx;
            }
        }

        selected[fi] = best_idx;
    }

    return selected;
}

/// Load and decode the SCIP index from .cog/index.scip.
fn loadIndex(allocator: std.mem.Allocator) !CodeIndex {
    const index_path = try getIndexPath(allocator);
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch {
        printErr("error: no index found. Run " ++ dim ++ "cog code:index" ++ reset ++ " first.\n");
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

/// Load and decode the SCIP index for long-lived runtime use.
pub fn loadIndexForRuntime(allocator: std.mem.Allocator) !CodeIndex {
    return loadIndex(allocator);
}

// ── Commands ────────────────────────────────────────────────────────────

pub fn dispatch(allocator: std.mem.Allocator, subcmd: []const u8, args: []const [:0]const u8) !void {
    if (std.mem.eql(u8, subcmd, "code:index")) return codeIndex(allocator, args);

    if (std.mem.eql(u8, subcmd, "code:query") or
        std.mem.eql(u8, subcmd, "code:status") or
        std.mem.eql(u8, subcmd, "code:edit") or
        std.mem.eql(u8, subcmd, "code:create") or
        std.mem.eql(u8, subcmd, "code:delete") or
        std.mem.eql(u8, subcmd, "code:rename"))
    {
        printErr("error: '");
        printErr(subcmd);
        printErr("' has been removed from CLI. Use the MCP tools instead (cog_code_*).\n");
        printErr("Run " ++ dim ++ "cog mcp --help" ++ reset ++ " for MCP server usage.\n");
        return error.Explained;
    }

    printErr("error: unknown command '");
    printErr(subcmd);
    printErr("'\nRun " ++ dim ++ "cog --help" ++ reset ++ " to see available commands.\n");
    return error.Explained;
}

// ── code:index ──────────────────────────────────────────────────────────

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

    if (patterns.items.len == 0) {
        const static_part = bold ++ "  cog code:index" ++ reset ++ " " ++ dim ++ "<pattern> [pattern...]" ++ reset ++ "\n"
            ++ "\n"
            ++ "  Specify one or more glob patterns to index.\n"
            ++ "\n"
            ++ cyan ++ bold ++ "  Examples" ++ reset ++ "\n"
            ++ "    cog code:index \"**/*.ts\"       " ++ dim ++ "All .ts files recursively" ++ reset ++ "\n"
            ++ "    cog code:index \"src/**/*.go\"   " ++ dim ++ "All .go files under src/" ++ reset ++ "\n"
            ++ "    cog code:index src/main.zig   " ++ dim ++ "A single file" ++ reset ++ "\n"
            ++ "\n"
            ++ cyan ++ bold ++ "  Built-in" ++ reset ++ "\n"
            ++ comptime builtinExtensionList()
            ++ "\n";

        const installed_block = listInstalledBlock(allocator);
        defer if (installed_block) |b| allocator.free(b);

        tui.header();
        if (installed_block) |block| {
            const combined = std.fmt.allocPrint(allocator, "{s}{s}", .{ static_part, block }) catch {
                printErr(static_part);
                printErr(block);
                return error.Explained;
            };
            defer allocator.free(combined);
            printErr(combined);
        } else {
            printErr(static_part);
        }

        return error.Explained;
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

    // Count indexable files (those with a recognized extension) for accurate progress
    var indexable_count: usize = 0;
    for (files.items) |file_path| {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) continue;
        if (extensions.isBuiltinSupported(ext)) {
            indexable_count += 1;
        } else if (extensions.resolveByExtension(allocator, ext)) |resolved| {
            extensions.freeExtension(allocator, &resolved);
            indexable_count += 1;
        }
    }

    // TTY progress display
    const show_progress = tui.isStderrTty();
    const total_files = indexable_count;
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
    var ext_files: [16]std.ArrayListUnmanaged([]const u8) = [_]std.ArrayListUnmanaged([]const u8){.empty} ** 16;
    var num_unique: usize = 0;

    for (files.items) |file_path| {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) continue;

        var resolved = extensions.resolveByExtension(allocator, ext) orelse continue;
        const idx = resolved.indexer orelse {
            extensions.freeExtension(allocator, &resolved);
            continue;
        };

        switch (idx) {
            .tree_sitter => |ts_config| {
                defer extensions.freeExtension(allocator, &resolved);

                if (show_progress) {
                    tui.progressUpdate(indexed_count, total_files, total_symbols, file_path);
                }

                // Read source file
                const source = readFileContents(allocator, file_path) orelse continue;
                defer allocator.free(source);

                // Index with tree-sitter
                if (indexer.indexFile(allocator, source, file_path, ts_config)) |result| {
                    backing_buffers.append(allocator, result.string_data) catch {};
                    mergeDocument(allocator, &master_index, result.doc);
                    indexed_count += 1;
                    total_symbols += result.doc.symbols.len;
                } else |_| {
                    // Indexing failed (e.g. Flow-typed JS parsed as plain JS).
                    // Still add a stub document so the file appears in the index
                    // and queries report "no symbols" instead of "file not found".
                    mergeDocument(allocator, &master_index, .{
                        .language = ts_config.scip_name,
                        .relative_path = file_path,
                        .occurrences = &.{},
                        .symbols = &.{},
                    });
                    indexed_count += 1;
                }

                if (show_progress) {
                    tui.progressUpdate(indexed_count, total_files, total_symbols, file_path);
                }
            },
            .scip_binary => {
                // Collect for batch external indexing
                var found = false;
                var found_idx: usize = 0;
                for (seen_names[0..num_unique], 0..) |name, i| {
                    if (std.mem.eql(u8, name, resolved.name)) {
                        found = true;
                        found_idx = i;
                        break;
                    }
                }
                if (!found and num_unique < 16) {
                    seen_names[num_unique] = resolved.name;
                    unique_exts[num_unique] = resolved;
                    ext_files[num_unique].append(allocator, file_path) catch {};
                    num_unique += 1;
                } else if (found) {
                    ext_files[found_idx].append(allocator, file_path) catch {};
                    extensions.freeExtension(allocator, &resolved);
                } else {
                    extensions.freeExtension(allocator, &resolved);
                }
            },
        }
    }

    // Invoke external indexers per-file for unsupported languages
    for (0..num_unique) |ext_idx| {
        const scip_config = switch (unique_exts[ext_idx].indexer orelse continue) {
            .scip_binary => |sc| sc,
            .tree_sitter => continue,
        };
        for (ext_files[ext_idx].items) |ext_file_path| {
            if (show_progress) {
                tui.progressUpdate(indexed_count, total_files, total_symbols, ext_file_path);
            }

            const result = invokeIndexerForFile(allocator, ext_file_path, scip_config) catch continue;

            backing_buffers.append(allocator, result.backing_data) catch {};
            mergeDocument(allocator, &master_index, result.doc);
            indexed_count += 1;
            total_symbols += result.doc.symbols.len;

            if (show_progress) {
                tui.progressUpdate(indexed_count, total_files, total_symbols, ext_file_path);
            }
        }
    }

    // Free installed extensions and file lists tracked during indexing
    for (0..num_unique) |ext_idx| {
        extensions.freeExtension(allocator, &unique_exts[ext_idx]);
        ext_files[ext_idx].deinit(allocator);
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
        const skipped = files.items.len - indexed_count;
        tui.progressFinish(indexed_count, total_symbols, skipped, index_path);
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

/// Returns true if the string contains glob wildcard characters (* or ?).
fn hasGlobChars(s: []const u8) bool {
    for (s) |c| {
        if (c == '*' or c == '?') return true;
    }
    return false;
}

/// Case-insensitive glob match for symbol names.
/// Supports `*` (zero or more chars) and `?` (one char).
/// Unlike `globMatch`, this has no path separator semantics — `*` matches any character.
fn nameGlobMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0; // pattern index
    var ni: usize = 0; // name index
    var star_pi: usize = 0;
    var star_ni: usize = 0;
    var has_star = false;

    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_ni = ni;
                has_star = true;
                pi += 1;
                continue;
            }
            if (ni < name.len) {
                if (pattern[pi] == '?' or std.ascii.toLower(pattern[pi]) == std.ascii.toLower(name[ni])) {
                    pi += 1;
                    ni += 1;
                    continue;
                }
            }
        }
        if (has_star and star_ni < name.len) {
            star_ni += 1;
            ni = star_ni;
            pi = star_pi + 1;
            continue;
        }
        return false;
    }
    return true;
}

/// Check if a file path matches a suffix filter.
/// Handles absolute vs relative path differences by trying exact match,
/// then endsWith in both directions.
fn fileMatchesSuffix(indexed_path: []const u8, filter: []const u8) bool {
    if (std.mem.eql(u8, indexed_path, filter)) return true;
    if (std.mem.endsWith(u8, filter, indexed_path)) return true;
    if (std.mem.endsWith(u8, indexed_path, filter)) return true;
    return false;
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
fn invokeIndexerForFile(allocator: std.mem.Allocator, file_path: []const u8, config: extensions.ScipBinaryConfig) !DocumentResult {
    // Create temp file for SCIP output
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/cog-index-{d}.scip", .{std.crypto.random.int(u64)});
    defer allocator.free(tmp_path);
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Substitute {file} and {output} in extension args
    const subs: []const settings_mod.Substitution = &.{
        .{ .key = "{file}", .value = file_path },
        .{ .key = "{output}", .value = tmp_path },
    };
    const sub_args = try settings_mod.substituteArgs(allocator, config.args, subs);
    defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

    // Build full command
    const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
    defer allocator.free(full_args);
    full_args[0] = config.command;
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
fn invokeProjectIndexer(allocator: std.mem.Allocator, target_path: []const u8, config: extensions.ScipBinaryConfig) !IndexResult {
    // Create temp file for SCIP output
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/cog-index-{d}.scip", .{std.crypto.random.int(u64)});
    defer allocator.free(tmp_path);
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Substitute {file} and {output} in extension args
    const subs: []const settings_mod.Substitution = &.{
        .{ .key = "{file}", .value = target_path },
        .{ .key = "{output}", .value = tmp_path },
    };
    const sub_args = try settings_mod.substituteArgs(allocator, config.args, subs);
    defer settings_mod.freeSubstitutedArgs(allocator, sub_args);

    // Build full command
    const full_args = try allocator.alloc([]const u8, 1 + sub_args.len);
    defer allocator.free(full_args);
    full_args[0] = config.command;
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

/// Remove a file from the SCIP index on disk.
/// Returns true if the file was found and removed, false otherwise.
/// Uses flock() advisory locking to serialize concurrent access.
pub fn removeFileFromIndex(allocator: std.mem.Allocator, file_path: []const u8) bool {
    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);

    const lock_fd = acquireIndexLock(allocator, cog_dir) orelse return false;
    defer releaseIndexLock(lock_fd);

    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    const before = master_index.documents.len;
    removeDocument(allocator, &master_index, file_path);
    if (master_index.documents.len == before) return false;

    return saveIndex(allocator, master_index, index_path);
}

/// Re-index a single file and update the master index.
/// Uses flock() advisory locking to serialize concurrent access.
pub fn reindexFile(allocator: std.mem.Allocator, file_path: []const u8) bool {
    const cog_dir = paths.findCogDir(allocator) catch return false;
    defer allocator.free(cog_dir);

    const lock_fd = acquireIndexLock(allocator, cog_dir) orelse return false;
    defer releaseIndexLock(lock_fd);

    const index_path = std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir}) catch return false;
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    const ext_str = std.fs.path.extension(file_path);
    if (ext_str.len == 0) return false;

    const resolved = extensions.resolveByExtension(allocator, ext_str) orelse return false;
    defer extensions.freeExtension(allocator, &resolved);

    const idx = resolved.indexer orelse return false;
    switch (idx) {
        .tree_sitter => |ts_config| {
            const source = readFileContents(allocator, file_path) orelse return false;
            defer allocator.free(source);

            var indexer = tree_sitter_indexer.Indexer.init();
            defer indexer.deinit();

            const result = indexer.indexFile(allocator, source, file_path, ts_config) catch return false;
            mergeDocument(allocator, &master_index, result.doc);

            // Encode and write (must happen before freeing string_data,
            // since symbol names are slices into it)
            const encoded = scip_encode.encodeIndex(allocator, master_index) catch {
                allocator.free(result.string_data);
                return false;
            };
            allocator.free(result.string_data);
            defer allocator.free(encoded);

            return writeEncodedIndexAtomically(allocator, index_path, encoded);
        },
        .scip_binary => |scip_config| {
            const file_result = invokeIndexerForFile(allocator, file_path, scip_config) catch return false;
            mergeDocument(allocator, &master_index, file_result.doc);

            const encoded = scip_encode.encodeIndex(allocator, master_index) catch {
                allocator.free(file_result.backing_data);
                return false;
            };
            allocator.free(file_result.backing_data);
            defer allocator.free(encoded);

            return writeEncodedIndexAtomically(allocator, index_path, encoded);
        },
    }
}

/// Write and save an index to disk.
fn saveIndex(allocator: std.mem.Allocator, index: scip.Index, index_path: []const u8) bool {
    const encoded = scip_encode.encodeIndex(allocator, index) catch return false;
    defer allocator.free(encoded);

    return writeEncodedIndexAtomically(allocator, index_path, encoded);
}

fn writeEncodedIndexAtomically(allocator: std.mem.Allocator, index_path: []const u8, encoded: []const u8) bool {
    const parent = std.fs.path.dirname(index_path) orelse return false;
    const basename = std.fs.path.basename(index_path);
    const tmp_name = std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ basename, std.time.nanoTimestamp() }) catch return false;
    defer allocator.free(tmp_name);

    var dir = std.fs.openDirAbsolute(parent, .{}) catch return false;
    defer dir.close();

    var tmp_file = dir.createFile(tmp_name, .{}) catch return false;
    var renamed = false;
    defer {
        tmp_file.close();
        if (!renamed) dir.deleteFile(tmp_name) catch {};
    }

    tmp_file.writeAll(encoded) catch return false;
    tmp_file.sync() catch return false;
    dir.rename(tmp_name, basename) catch return false;
    renamed = true;
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

    // Determine query mode: exactly one of --find, --refs, --symbols
    const find_name = findFlag(args, "--find");
    const refs_name = findFlag(args, "--refs");
    const symbols_file = findFlag(args, "--symbols");

    const mode_count = @as(usize, if (find_name != null) 1 else 0) +
        @as(usize, if (refs_name != null) 1 else 0) +
        @as(usize, if (symbols_file != null) 1 else 0);

    if (mode_count == 0) {
        printErr("error: specify one of --find, --refs, or --symbols\nRun " ++ dim ++ "cog code/query --help" ++ reset ++ " for usage.\n");
        return error.Explained;
    }
    if (mode_count > 1) {
        printErr("error: specify only one of --find, --refs, or --symbols\n");
        return error.Explained;
    }

    if (find_name) |name| return queryFind(allocator, args, name);
    if (refs_name) |name| return queryRefs(allocator, args, name);
    if (symbols_file) |file_path| return querySymbols(allocator, args, file_path);
}

fn queryFind(allocator: std.mem.Allocator, args: []const [:0]const u8, name: []const u8) !void {
    const kind_filter: ?[]const u8 = if (findFlag(args, "--kind")) |k| @as([]const u8, k) else null;
    const file_filter: ?[]const u8 = if (findFlag(args, "--file")) |f| @as([]const u8, f) else null;

    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    var matches = try ci.findSymbol(allocator, name, kind_filter, file_filter);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) {
        printErr("error: no symbol found matching '");
        printErr(name);
        printErr("'\n");
        return error.Explained;
    }

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginArray();
    for (matches.items) |match| {
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

    const result = try aw.toOwnedSlice();
    defer allocator.free(result);
    printStdout(result);
}

fn queryRefs(allocator: std.mem.Allocator, args: []const [:0]const u8, name: []const u8) !void {
    const kind_filter: ?[]const u8 = if (findFlag(args, "--kind")) |k| @as([]const u8, k) else null;

    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    var matches = try ci.findSymbol(allocator, name, kind_filter, null);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) {
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
        for (refs.items) |ref| {
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
            if (fileMatchesSuffix(indexed_path, file_path)) {
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
        if (extensions.resolveByExtension(allocator, ext_str)) |resolved| {
            defer extensions.freeExtension(allocator, &resolved);
            if (resolved.indexer) |idx| {
                switch (idx) {
                    .tree_sitter => |ts_config| {
                        if (readFileContents(allocator, new_path)) |source| {
                            defer allocator.free(source);
                            var indexer = tree_sitter_indexer.Indexer.init();
                            defer indexer.deinit();
                            if (indexer.indexFile(allocator, source, new_path, ts_config)) |result| {
                                reindex_string_data = result.string_data;
                                mergeDocument(allocator, &master_index, result.doc);
                                reindexed = true;
                            } else |_| {}
                        }
                    },
                    .scip_binary => |scip_config| {
                        if (invokeIndexerForFile(allocator, new_path, scip_config)) |file_result| {
                            reindex_backing = file_result.backing_data;
                            mergeDocument(allocator, &master_index, file_result.doc);
                            reindexed = true;
                        } else |_| {}
                    },
                }
            }
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

// ── Public Inner API (for MCP server) ───────────────────────────────────

pub const QueryMode = enum { find, refs, symbols };

pub const QueryParams = struct {
    mode: QueryMode,
    name: ?[]const u8 = null,
    file: ?[]const u8 = null,
    kind: ?[]const u8 = null,
};

pub fn codeQueryInner(allocator: std.mem.Allocator, params: QueryParams) ![]const u8 {
    var ci = try loadIndex(allocator);
    defer ci.deinit(allocator);

    return codeQueryWithLoadedIndex(allocator, &ci, params);
}

pub fn codeQueryWithLoadedIndex(allocator: std.mem.Allocator, ci: *CodeIndex, params: QueryParams) ![]const u8 {
    return switch (params.mode) {
        .find => try queryFindInner(allocator, ci, params.name orelse return error.MissingName, params.kind, params.file),
        .refs => try queryRefsInner(allocator, ci, params.name orelse return error.MissingName, params.kind, params.file),
        .symbols => try querySymbolsInner(allocator, ci, params.file orelse return error.MissingFile, params.kind),
    };
}

// ── Explore API (composite find + read) ─────────────────────────────────

pub const ExploreQuery = struct {
    name: []const u8,
    kind: ?[]const u8 = null,
};

pub fn codeExploreWithLoadedIndex(allocator: std.mem.Allocator, ci: *CodeIndex, queries: []const ExploreQuery, context_lines: usize) ![]const u8 {
    // Resolve the project root from .cog dir (strip trailing /.cog)
    const cog_dir = paths.findCogDir(allocator) catch return try allocator.dupe(u8, "[]");
    defer allocator.free(cog_dir);
    const project_root = std.fs.path.dirname(cog_dir) orelse return try allocator.dupe(u8, "[]");

    // Phase 1: Gather all candidates
    const n = @min(queries.len, MAX_EXPLORE_QUERIES);
    var all_matches: [MAX_EXPLORE_QUERIES]CodeIndex.MatchList = undefined;
    for (0..n) |i| {
        all_matches[i] = ci.findSymbol(allocator, queries[i].name, queries[i].kind, null) catch .empty;
    }
    defer for (0..n) |i| all_matches[i].deinit(allocator);

    // Phase 2: Auto-retry not-found queries with *name* glob
    var retry_used: [MAX_EXPLORE_QUERIES]bool = .{false} ** MAX_EXPLORE_QUERIES;
    var retry_globs: [MAX_EXPLORE_QUERIES]?[]const u8 = .{null} ** MAX_EXPLORE_QUERIES;
    defer for (&retry_globs) |*rg| {
        if (rg.*) |g| allocator.free(g);
    };

    for (0..n) |i| {
        if (all_matches[i].items.len > 0) continue;
        // Skip if already a glob pattern
        if (hasGlobChars(queries[i].name)) continue;
        const glob_name = try std.fmt.allocPrint(allocator, "*{s}*", .{queries[i].name});
        retry_globs[i] = glob_name;
        all_matches[i] = ci.findSymbol(allocator, glob_name, queries[i].kind, null) catch .empty;
        if (all_matches[i].items.len > 0) retry_used[i] = true;
    }

    // Phase 3: Disambiguate using batch coherence
    const selected = try disambiguateBatch(allocator, ci, all_matches[0..n]);
    defer allocator.free(selected);

    // Phase 4: Read definition bodies and collect queried file/symbol info
    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);

    // Store body results for primary queries
    var body_results: [MAX_EXPLORE_QUERIES]?ReadBodyResult = .{null} ** MAX_EXPLORE_QUERIES;
    defer for (&body_results) |*br| {
        if (br.*) |r| allocator.free(r.snippet);
    };

    var total_bytes: usize = 0;

    for (0..n) |i| {
        const matches = &all_matches[i];
        if (matches.items.len == 0) continue;
        const sel_idx = selected[i] orelse 0;
        const match = matches.items[sel_idx];
        if (match.def.path.len == 0) continue;

        // Track queried symbols so file_symbols TOC excludes them
        queried_symbols.put(allocator, match.symbol, {}) catch {};

        // Read full definition body
        const body = readDefinitionBody(allocator, project_root, match.def.path, match.def.line, match.def.end_line, context_lines) catch null;
        if (body) |b| {
            total_bytes += b.snippet.len;
            body_results[i] = b;
        }
    }

    // Phase 5: Output JSON
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginArray();

    // Track files we've already emitted TOCs for (avoid duplicates across queries)
    var emitted_file_tocs: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted_file_tocs.deinit(allocator);

    // Primary results
    for (0..n) |i| {
        const matches = &all_matches[i];
        if (matches.items.len == 0) {
            try writeExploreError(&s, queries[i].name, "Symbol not found");
            continue;
        }

        const sel_idx = selected[i] orelse 0;
        const match = matches.items[sel_idx];

        if (match.def.path.len == 0) {
            try writeExploreError(&s, queries[i].name, "Symbol is external (no source file)");
            continue;
        }

        try s.beginObject();
        try s.objectField("name");
        try s.write(if (match.def.display_name.len > 0) match.def.display_name else scip.extractSymbolName(match.symbol));
        try s.objectField("kind");
        try s.write(scip.kindName(match.def.kind));
        try s.objectField("path");
        try s.write(match.def.path);
        try s.objectField("line");
        try s.write(match.def.line);
        if (match.def.end_line > match.def.line) {
            try s.objectField("end_line");
            try s.write(match.def.end_line);
        }
        if (body_results[i]) |body| {
            try s.objectField("snippet");
            try s.write(body.snippet);
        }
        // Emit references from SCIP cross-reference data
        if (match.def.end_line > match.def.line) {
            var refs = ci.findReferencesInRange(allocator, match.def.path, match.symbol, match.def.line, match.def.end_line);
            defer refs.deinit(allocator);
            if (refs.items.len > 0) {
                try s.objectField("references");
                try s.beginArray();
                for (refs.items) |ref_name| {
                    try s.write(ref_name);
                }
                try s.endArray();
            }
        }
        // Emit file_symbols TOC (once per unique file)
        if (!emitted_file_tocs.contains(match.def.path)) {
            emitted_file_tocs.put(allocator, match.def.path, {}) catch {};
            var toc = ci.getFileSymbolsTOC(allocator, match.def.path, &queried_symbols);
            defer toc.deinit(allocator);
            if (toc.items.len > 0) {
                try s.objectField("file_symbols");
                try s.beginArray();
                for (toc.items) |entry| {
                    try s.beginObject();
                    try s.objectField("name");
                    try s.write(entry.name);
                    try s.objectField("kind");
                    try s.write(scip.kindName(entry.kind));
                    try s.objectField("line");
                    try s.write(entry.line);
                    if (entry.end_line > entry.line) {
                        try s.objectField("end_line");
                        try s.write(entry.end_line);
                    }
                    try s.endObject();
                }
                try s.endArray();
            }
        }
        if (retry_used[i]) {
            try s.objectField("retry");
            try s.write(retry_globs[i].?);
        }
        try s.endObject();
    }

    try s.endArray();

    return aw.toOwnedSlice();
}

fn writeExploreError(s: *Stringify, name: []const u8, err_msg: []const u8) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("error");
    try s.write(err_msg);
    try s.endObject();
}

fn readSnippet(allocator: std.mem.Allocator, project_root: []const u8, rel_path: []const u8, def_line: i32, context_lines: usize) ![]const u8 {
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Find line boundaries
    const target: usize = if (def_line > 0) @intCast(def_line) else 0;
    const start_line = if (target >= context_lines) target - context_lines else 0;
    const end_line = target + context_lines;

    var line_num: usize = 0;
    var start_offset: usize = 0;
    var end_offset: usize = content.len;
    var i: usize = 0;

    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line_num += 1;
            if (line_num == start_line) {
                start_offset = i + 1;
            }
            if (line_num == end_line) {
                end_offset = i;
                break;
            }
        }
    }

    if (start_offset >= content.len) start_offset = content.len;
    if (end_offset > content.len) end_offset = content.len;
    if (start_offset > end_offset) start_offset = end_offset;

    return try allocator.dupe(u8, content[start_offset..end_offset]);
}

const ReadBodyResult = struct {
    snippet: []const u8,
    truncated: bool,
};

fn readDefinitionBody(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    rel_path: []const u8,
    def_line: i32,
    def_end_line: i32,
    fallback_context: usize,
) !ReadBodyResult {
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel_path });
    defer allocator.free(abs_path);

    const file = try std.fs.openFileAbsolute(abs_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Split into lines
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);
    var line_start: usize = 0;
    for (content, 0..) |ch, idx| {
        if (ch == '\n') {
            try lines.append(allocator, content[line_start..idx]);
            line_start = idx + 1;
        }
    }
    if (line_start < content.len) {
        try lines.append(allocator, content[line_start..]);
    }

    if (lines.items.len == 0) return .{ .snippet = try allocator.dupe(u8, ""), .truncated = false };

    const raw_target: usize = if (def_line > 0) @intCast(def_line) else 0;
    const target: usize = @min(raw_target, lines.items.len - 1);

    // Walk backward from def_line for doc comments (up to CONTEXT_BEFORE lines)
    var doc_start = target;
    {
        var look: usize = 0;
        while (look < CONTEXT_BEFORE and doc_start > 0) : (look += 1) {
            const prev = lines.items[doc_start - 1];
            const trimmed = std.mem.trimLeft(u8, prev, " \t");
            if (trimmed.len == 0) break;
            if (std.mem.startsWith(u8, trimmed, "///") or
                std.mem.startsWith(u8, trimmed, "//!") or
                std.mem.startsWith(u8, trimmed, "//") or
                std.mem.startsWith(u8, trimmed, "/*") or
                std.mem.startsWith(u8, trimmed, "* ") or
                std.mem.startsWith(u8, trimmed, "*/") or
                std.mem.startsWith(u8, trimmed, "#") or
                std.mem.startsWith(u8, trimmed, "@"))
            {
                doc_start -= 1;
            } else {
                break;
            }
        }
    }

    // Determine end line
    const has_enclosing_range = def_end_line > def_line;
    const end_line: usize = if (has_enclosing_range)
        @min(@as(usize, @intCast(def_end_line)), lines.items.len - 1)
    else blk: {
        // No enclosing_range — fallback to ±fallback_context window
        break :blk @min(target + fallback_context, lines.items.len - 1);
    };

    // When no enclosing_range, extend doc_start to include fallback window before target
    const actual_start = if (has_enclosing_range)
        doc_start
    else
        @min(doc_start, if (target >= fallback_context) target - fallback_context else 0);

    // Cap at MAX_BODY_LINES
    const capped_end = @min(end_line, actual_start + MAX_BODY_LINES - 1);
    const truncated = capped_end < end_line;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (actual_start..capped_end + 1) |li| {
        try buf.appendSlice(allocator, lines.items[li]);
        try buf.append(allocator, '\n');
    }
    return .{
        .snippet = try buf.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

const RelatedSymbol = struct {
    symbol: []const u8,
    def: DefInfo,
    relevance: usize,
};

fn discoverRelatedSymbols(
    allocator: std.mem.Allocator,
    ci: *const CodeIndex,
    queried_files: []const []const u8,
    queried_symbols: *const std.StringHashMapUnmanaged(void),
    max_related: usize,
) !std.ArrayListUnmanaged(RelatedSymbol) {
    // Build occurrence sets for each unique queried file
    var file_occ_sets: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    defer {
        for (file_occ_sets.items) |*s| s.deinit(allocator);
        file_occ_sets.deinit(allocator);
    }

    // Track unique files to avoid building duplicate sets
    var seen_files: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_files.deinit(allocator);

    for (queried_files) |file_path| {
        if (seen_files.contains(file_path)) continue;
        seen_files.put(allocator, file_path, {}) catch continue;
        const occ_set = ci.buildFileOccurrenceSet(allocator, file_path);
        try file_occ_sets.append(allocator, occ_set);
    }

    // Collect candidate symbols and score by how many queried files reference them
    var candidates: std.StringHashMapUnmanaged(RelatedSymbol) = .empty;
    defer candidates.deinit(allocator);

    for (file_occ_sets.items) |occ_set| {
        var occ_iter = occ_set.iterator();
        while (occ_iter.next()) |entry| {
            const sym = entry.key_ptr.*;
            // Skip already-queried symbols
            if (queried_symbols.contains(sym)) continue;

            // Look up def info — skip external symbols
            const def = ci.symbol_to_defs.get(sym) orelse continue;
            if (def.path.len == 0) continue;

            const existing = candidates.getOrPut(allocator, sym) catch continue;
            if (!existing.found_existing) {
                existing.value_ptr.* = .{
                    .symbol = sym,
                    .def = def,
                    .relevance = 1,
                };
            } else {
                existing.value_ptr.relevance += 1;
            }
        }
    }

    // Collect into sortable list
    var result: std.ArrayListUnmanaged(RelatedSymbol) = .empty;
    errdefer result.deinit(allocator);
    var cand_iter = candidates.iterator();
    while (cand_iter.next()) |entry| {
        try result.append(allocator, entry.value_ptr.*);
    }

    // Sort by relevance descending, then kind priority (struct=49 > function=12 > others)
    const SortCtx = struct {
        fn lessThan(_: void, a: RelatedSymbol, b: RelatedSymbol) bool {
            if (a.relevance != b.relevance) return a.relevance > b.relevance;
            return kindPriority(a.def.kind) > kindPriority(b.def.kind);
        }

        fn kindPriority(kind: i32) u8 {
            return switch (kind) {
                49 => 3, // struct
                7 => 3, // class
                12 => 2, // function
                24 => 2, // method
                else => 1,
            };
        }
    };
    std.mem.sortUnstable(RelatedSymbol, result.items, {}, SortCtx.lessThan);

    // Truncate to max_related
    if (result.items.len > max_related) {
        result.items.len = max_related;
    }

    return result;
}

fn queryFindInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8, kind_filter: ?[]const u8, file_filter: ?[]const u8) ![]const u8 {
    var matches = try ci.findSymbol(allocator, name, kind_filter, file_filter);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return try allocator.dupe(u8, "Symbol not found");

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginArray();
    for (matches.items) |match| {
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

    return aw.toOwnedSlice();
}

fn queryRefsInner(allocator: std.mem.Allocator, ci: *CodeIndex, name: []const u8, kind_filter: ?[]const u8, file_filter: ?[]const u8) ![]const u8 {
    var matches = try ci.findSymbol(allocator, name, kind_filter, null);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return try allocator.dupe(u8, "Symbol not found");

    const match = matches.items[0];
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
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

    var total_refs: usize = 0;
    if (ci.symbol_to_refs.get(match.symbol)) |refs| {
        total_refs = refs.items.len;
        for (refs.items) |ref| {
            if (file_filter) |ff| {
                if (!fileMatchesSuffix(ref.path, ff)) continue;
            }
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
    try s.objectField("total_references");
    try s.write(total_refs);
    try s.endObject();
    return aw.toOwnedSlice();
}

fn querySymbolsInner(allocator: std.mem.Allocator, ci: *CodeIndex, file_path: []const u8, kind_filter: ?[]const u8) ![]const u8 {
    // Try exact match first
    var doc_idx_opt = ci.path_to_doc_idx.get(file_path);
    if (doc_idx_opt == null) {
        var iter = ci.path_to_doc_idx.iterator();
        while (iter.next()) |entry| {
            const indexed_path = entry.key_ptr.*;
            if (fileMatchesSuffix(indexed_path, file_path)) {
                doc_idx_opt = entry.value_ptr.*;
                break;
            }
        }
    }
    const doc_idx = doc_idx_opt orelse return try allocator.dupe(u8, "File not found in index");
    const doc = ci.index.documents[doc_idx];

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
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
        const display = if (sym.display_name.len > 0) sym.display_name else scip.extractSymbolName(sym.symbol);
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
    return aw.toOwnedSlice();
}

pub fn codeEditInner(allocator: std.mem.Allocator, file_path: []const u8, old_text: []const u8, new_text: []const u8) ![]const u8 {
    const s = settings_mod.Settings.load(allocator);
    defer if (s) |ss| ss.deinit(allocator);

    const use_external = if (s) |ss| ss.editor != null else false;
    if (use_external) {
        const editor_cfg = s.?.editor.?;
        const subs: []const settings_mod.Substitution = &.{
            .{ .key = "{file}", .value = file_path },
            .{ .key = "{old}", .value = old_text },
            .{ .key = "{new}", .value = new_text },
        };
        try runExternalTool(allocator, editor_cfg, subs);
    } else {
        try builtinEdit(allocator, file_path, old_text, new_text);
    }

    const reindexed = reindexFile(allocator, file_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("edited");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeCreateInner(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
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

    const reindexed = reindexFile(allocator, file_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("created");
    try st.write(true);
    try st.objectField("reindexed");
    try st.write(reindexed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeDeleteInner(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
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

    const removed = removeFromIndex(allocator, file_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("file");
    try st.write(file_path);
    try st.objectField("deleted");
    try st.write(true);
    try st.objectField("index_updated");
    try st.write(removed);
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeRenameInner(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) ![]const u8 {
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

    // Update index
    const cog_dir = paths.findCogDir(allocator) catch {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
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
        return aw.toOwnedSlice();
    };
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    const loaded = loadExistingIndex(allocator, index_path);
    var master_index = loaded.index;
    defer scip.freeIndex(allocator, &master_index);
    defer if (loaded.backing_data) |data| allocator.free(data);

    removeDocument(allocator, &master_index, old_path);

    var reindexed = false;
    var reindex_backing: ?[]const u8 = null;
    var reindex_string_data: ?[]const u8 = null;
    defer if (reindex_backing) |data| allocator.free(data);
    defer if (reindex_string_data) |data| allocator.free(data);
    const ext_str = std.fs.path.extension(new_path);
    if (ext_str.len > 0) {
        if (extensions.resolveByExtension(allocator, ext_str)) |resolved| {
            defer extensions.freeExtension(allocator, &resolved);
            if (resolved.indexer) |idx| {
                switch (idx) {
                    .tree_sitter => |ts_config| {
                        if (readFileContents(allocator, new_path)) |source| {
                            defer allocator.free(source);
                            var indexer = tree_sitter_indexer.Indexer.init();
                            defer indexer.deinit();
                            if (indexer.indexFile(allocator, source, new_path, ts_config)) |result| {
                                reindex_string_data = result.string_data;
                                mergeDocument(allocator, &master_index, result.doc);
                                reindexed = true;
                            } else |_| {}
                        }
                    },
                    .scip_binary => |scip_config| {
                        if (invokeIndexerForFile(allocator, new_path, scip_config)) |file_result| {
                            reindex_backing = file_result.backing_data;
                            mergeDocument(allocator, &master_index, file_result.doc);
                            reindexed = true;
                        } else |_| {}
                    },
                }
            }
        }
    }
    _ = saveIndex(allocator, master_index, index_path);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
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
    return aw.toOwnedSlice();
}

pub fn codeStatusInner(allocator: std.mem.Allocator) ![]const u8 {
    const index_path = getIndexPath(allocator) catch {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var st: Stringify = .{ .writer = &aw.writer };
        try st.beginObject();
        try st.objectField("exists");
        try st.write(false);
        try st.endObject();
        return aw.toOwnedSlice();
    };
    defer allocator.free(index_path);

    const file = std.fs.openFileAbsolute(index_path, .{}) catch {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var st: Stringify = .{ .writer = &aw.writer };
        try st.beginObject();
        try st.objectField("exists");
        try st.write(false);
        try st.endObject();
        return aw.toOwnedSlice();
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024 * 1024) catch return error.ReadFailed;
    defer allocator.free(data);

    var index = scip.decode(allocator, data) catch return error.DecodeFailed;
    defer scip.freeIndex(allocator, &index);

    var total_symbols: usize = 0;
    for (index.documents) |doc| {
        total_symbols += doc.symbols.len;
    }
    total_symbols += index.external_symbols.len;

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("exists");
    try st.write(true);
    try st.objectField("path");
    try st.write(index_path);
    try st.objectField("documents");
    try st.write(index.documents.len);
    try st.objectField("symbols");
    try st.write(total_symbols);
    if (index.metadata.tool_info.name.len > 0) {
        try st.objectField("indexer");
        try st.write(index.metadata.tool_info.name);
    }
    if (index.metadata.project_root.len > 0) {
        try st.objectField("project_root");
        try st.write(index.metadata.project_root);
    }
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeStatusFromLoadedIndex(allocator: std.mem.Allocator, ci: *const CodeIndex) ![]const u8 {
    var total_symbols: usize = 0;
    for (ci.index.documents) |doc| {
        total_symbols += doc.symbols.len;
    }
    total_symbols += ci.index.external_symbols.len;

    const index_path = getIndexPath(allocator) catch null;
    defer if (index_path) |p| allocator.free(p);

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("exists");
    try st.write(true);
    if (index_path) |p| {
        try st.objectField("path");
        try st.write(p);
    }
    try st.objectField("documents");
    try st.write(ci.index.documents.len);
    try st.objectField("symbols");
    try st.write(total_symbols);
    if (ci.index.metadata.tool_info.name.len > 0) {
        try st.objectField("indexer");
        try st.write(ci.index.metadata.tool_info.name);
    }
    if (ci.index.metadata.project_root.len > 0) {
        try st.objectField("project_root");
        try st.write(ci.index.metadata.project_root);
    }
    try st.endObject();
    return aw.toOwnedSlice();
}

pub fn codeIndexInner(allocator: std.mem.Allocator, pattern_list: ?[]const []const u8) ![]const u8 {
    var patterns_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    defer patterns_buf.deinit(allocator);

    if (pattern_list) |pl| {
        for (pl) |p| try patterns_buf.append(allocator, p);
    }
    if (patterns_buf.items.len == 0) {
        try patterns_buf.append(allocator, "**/*");
    }

    const cog_dir = paths.findOrCreateCogDir(allocator) catch return error.NoCogDir;
    defer allocator.free(cog_dir);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.scip", .{cog_dir});
    defer allocator.free(index_path);

    std.fs.makeDirAbsolute(cog_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.MkdirFailed,
    };

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

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    for (patterns_buf.items) |pattern| {
        collectGlobFiles(allocator, pattern, &files) catch continue;
    }

    if (files.items.len == 0) return error.NoFilesMatched;

    var indexed_count: usize = 0;
    var total_symbols: usize = 0;

    var indexer = tree_sitter_indexer.Indexer.init();
    defer indexer.deinit();

    var seen_names: [16][]const u8 = undefined;
    var unique_exts: [16]extensions.Extension = undefined;
    var ext_files: [16]std.ArrayListUnmanaged([]const u8) = [_]std.ArrayListUnmanaged([]const u8){.empty} ** 16;
    var num_unique: usize = 0;

    for (files.items) |file_path| {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) continue;

        var resolved = extensions.resolveByExtension(allocator, ext) orelse continue;
        const idx_config = resolved.indexer orelse {
            extensions.freeExtension(allocator, &resolved);
            continue;
        };

        switch (idx_config) {
            .tree_sitter => |ts_config| {
                defer extensions.freeExtension(allocator, &resolved);
                const source = readFileContents(allocator, file_path) orelse continue;
                defer allocator.free(source);
                if (indexer.indexFile(allocator, source, file_path, ts_config)) |result| {
                    backing_buffers.append(allocator, result.string_data) catch {};
                    mergeDocument(allocator, &master_index, result.doc);
                    indexed_count += 1;
                    total_symbols += result.doc.symbols.len;
                } else |_| {
                    mergeDocument(allocator, &master_index, .{
                        .language = ts_config.scip_name,
                        .relative_path = file_path,
                        .occurrences = &.{},
                        .symbols = &.{},
                    });
                    indexed_count += 1;
                }
            },
            .scip_binary => {
                var found = false;
                var found_idx: usize = 0;
                for (seen_names[0..num_unique], 0..) |name, i| {
                    if (std.mem.eql(u8, name, resolved.name)) {
                        found = true;
                        found_idx = i;
                        break;
                    }
                }
                if (!found and num_unique < 16) {
                    seen_names[num_unique] = resolved.name;
                    unique_exts[num_unique] = resolved;
                    ext_files[num_unique].append(allocator, file_path) catch {};
                    num_unique += 1;
                } else if (found) {
                    ext_files[found_idx].append(allocator, file_path) catch {};
                    extensions.freeExtension(allocator, &resolved);
                } else {
                    extensions.freeExtension(allocator, &resolved);
                }
            },
        }
    }

    for (0..num_unique) |ext_idx| {
        const scip_config = switch (unique_exts[ext_idx].indexer orelse continue) {
            .scip_binary => |sc| sc,
            .tree_sitter => continue,
        };
        for (ext_files[ext_idx].items) |ext_file_path| {
            const result = invokeIndexerForFile(allocator, ext_file_path, scip_config) catch continue;
            backing_buffers.append(allocator, result.backing_data) catch {};
            mergeDocument(allocator, &master_index, result.doc);
            indexed_count += 1;
            total_symbols += result.doc.symbols.len;
        }
    }

    for (0..num_unique) |ext_idx| {
        extensions.freeExtension(allocator, &unique_exts[ext_idx]);
        ext_files[ext_idx].deinit(allocator);
    }

    const encoded = scip_encode.encodeIndex(allocator, master_index) catch return error.EncodeFailed;
    defer allocator.free(encoded);

    if (!writeEncodedIndexAtomically(allocator, index_path, encoded)) return error.WriteFailed;

    total_symbols += master_index.external_symbols.len;

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var st: Stringify = .{ .writer = &aw.writer };
    try st.beginObject();
    try st.objectField("files_indexed");
    try st.write(indexed_count);
    try st.objectField("documents");
    try st.write(master_index.documents.len);
    try st.objectField("symbols");
    try st.write(total_symbols);
    try st.objectField("path");
    try st.write(index_path);
    try st.endObject();
    return aw.toOwnedSlice();
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
    var matches = try ci.findSymbol(allocator, "Foo", null, null);
    defer matches.deinit(allocator);
    try std.testing.expect(matches.items.len > 0);
    try std.testing.expectEqualStrings("pkg/Foo#", matches.items[0].symbol);
    try std.testing.expectEqual(@as(i32, 10), matches.items[0].def.line);

    // Test findSymbol with kind filter
    var method_matches = try ci.findSymbol(allocator, "bar", "method", null);
    defer method_matches.deinit(allocator);
    try std.testing.expect(method_matches.items.len > 0);

    var struct_matches = try ci.findSymbol(allocator, "bar", "struct", null);
    defer struct_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), struct_matches.items.len);

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
    const allocator = std.testing.allocator;
    var matches: CodeIndex.MatchList = .empty;
    defer matches.deinit(allocator);
    try matches.append(allocator, .{ .symbol = "a", .def = .{ .path = "a.go", .line = 0, .kind = 0, .display_name = "a", .documentation = &.{} }, .score = 10 });
    try matches.append(allocator, .{ .symbol = "b", .def = .{ .path = "b.go", .line = 0, .kind = 0, .display_name = "b", .documentation = &.{} }, .score = 50 });
    try matches.append(allocator, .{ .symbol = "c", .def = .{ .path = "c.go", .line = 0, .kind = 0, .display_name = "c", .documentation = &.{} }, .score = 30 });

    CodeIndex.sortMatchesByScore(&matches);

    try std.testing.expectEqual(@as(u8, 50), matches.items[0].score);
    try std.testing.expectEqual(@as(u8, 30), matches.items[1].score);
    try std.testing.expectEqual(@as(u8, 10), matches.items[2].score);
}

test "nameGlobMatch" {
    // Exact match (case insensitive)
    try std.testing.expect(nameGlobMatch("Foo", "Foo"));
    try std.testing.expect(nameGlobMatch("foo", "Foo"));
    try std.testing.expect(nameGlobMatch("FOO", "foo"));

    // Star wildcard
    try std.testing.expect(nameGlobMatch("*init*", "initServer"));
    try std.testing.expect(nameGlobMatch("*init*", "serverInit"));
    try std.testing.expect(nameGlobMatch("*init*", "myInitFunc"));
    try std.testing.expect(nameGlobMatch("*init*", "init"));
    try std.testing.expect(!nameGlobMatch("*init*", "configure"));

    // Prefix/suffix patterns
    try std.testing.expect(nameGlobMatch("get*", "getUser"));
    try std.testing.expect(nameGlobMatch("get*", "Get"));
    try std.testing.expect(!nameGlobMatch("get*", "forget"));
    try std.testing.expect(nameGlobMatch("*Handler", "RequestHandler"));
    try std.testing.expect(!nameGlobMatch("*Handler", "handle"));

    // Question mark
    try std.testing.expect(nameGlobMatch("?oo", "Foo"));
    try std.testing.expect(nameGlobMatch("?oo", "foo"));
    try std.testing.expect(!nameGlobMatch("?oo", "Fooo"));

    // Match-all
    try std.testing.expect(nameGlobMatch("*", "anything"));
    try std.testing.expect(nameGlobMatch("*", ""));
}

test "hasGlobChars" {
    try std.testing.expect(hasGlobChars("*init*"));
    try std.testing.expect(hasGlobChars("foo?"));
    try std.testing.expect(hasGlobChars("get*"));
    try std.testing.expect(!hasGlobChars("init"));
    try std.testing.expect(!hasGlobChars(""));
    try std.testing.expect(!hasGlobChars("foo.bar"));
}

test "fileMatchesSuffix" {
    // Exact match
    try std.testing.expect(fileMatchesSuffix("src/main.zig", "src/main.zig"));

    // Suffix match: indexed path ends with filter
    try std.testing.expect(fileMatchesSuffix("src/main.zig", "main.zig"));

    // Prefix match: filter ends with indexed path
    try std.testing.expect(fileMatchesSuffix("main.zig", "/Users/foo/project/main.zig"));

    // No match
    try std.testing.expect(!fileMatchesSuffix("src/main.zig", "other.zig"));
    try std.testing.expect(!fileMatchesSuffix("src/main.zig", "src/other.zig"));
}

test "findSymbol with glob patterns" {
    const allocator = std.testing.allocator;

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
        .kind = 49,
        .display_name = "Foo",
        .enclosing_symbol = "",
    };
    doc_symbols[1] = .{
        .symbol = "pkg/Foo#bar().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 26,
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
            .tool_info = .{ .name = "test", .version = "1.0" },
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

    // Glob pattern matching
    var glob_matches = try ci.findSymbol(allocator, "*oo*", null, null);
    defer glob_matches.deinit(allocator);
    try std.testing.expect(glob_matches.items.len > 0);
    // Should find "Foo" (display_name contains "oo")
    try std.testing.expectEqualStrings("pkg/Foo#", glob_matches.items[0].symbol);

    // Glob pattern with star prefix
    var bar_matches = try ci.findSymbol(allocator, "*ar", null, null);
    defer bar_matches.deinit(allocator);
    try std.testing.expect(bar_matches.items.len > 0);
    try std.testing.expectEqualStrings("pkg/Foo#bar().", bar_matches.items[0].symbol);

    // File filter matching
    var file_matches = try ci.findSymbol(allocator, "Foo", null, "foo.go");
    defer file_matches.deinit(allocator);
    try std.testing.expect(file_matches.items.len > 0);

    // File filter non-matching
    var no_file_matches = try ci.findSymbol(allocator, "Foo", null, "other.go");
    defer no_file_matches.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_file_matches.items.len);
}

// ── Disambiguation Tests ────────────────────────────────────────────────

/// Helper to build a synthetic CodeIndex for disambiguation tests.
/// File A (src/commands.zig): defines init (function), initBrain (function), references Settings symbol
/// File B (src/settings.zig): defines Settings (struct), load (function)
/// File C (src/http.zig): defines init (function) — unrelated init
fn buildTestDisambiguationIndex(allocator: std.mem.Allocator) !CodeIndex {
    // File A: src/commands.zig — defines init, initBrain, references Settings
    var occ_a = try allocator.alloc(scip.Occurrence, 3);
    occ_a[0] = .{
        .range = .{ .start_line = 5, .start_char = 0, .end_line = 5, .end_char = 4 },
        .symbol = "proj/commands.zig/init().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occ_a[1] = .{
        .range = .{ .start_line = 20, .start_char = 0, .end_line = 20, .end_char = 9 },
        .symbol = "proj/commands.zig/initBrain().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occ_a[2] = .{
        .range = .{ .start_line = 10, .start_char = 4, .end_line = 10, .end_char = 12 },
        .symbol = "proj/settings.zig/Settings#",
        .symbol_roles = 0, // reference, not definition
        .syntax_kind = 0,
    };

    var sym_a = try allocator.alloc(scip.SymbolInformation, 2);
    sym_a[0] = .{
        .symbol = "proj/commands.zig/init().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "init",
        .enclosing_symbol = "",
    };
    sym_a[1] = .{
        .symbol = "proj/commands.zig/initBrain().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "initBrain",
        .enclosing_symbol = "",
    };

    // File B: src/settings.zig — defines Settings, load
    var occ_b = try allocator.alloc(scip.Occurrence, 2);
    occ_b[0] = .{
        .range = .{ .start_line = 3, .start_char = 0, .end_line = 3, .end_char = 8 },
        .symbol = "proj/settings.zig/Settings#",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };
    occ_b[1] = .{
        .range = .{ .start_line = 30, .start_char = 0, .end_line = 30, .end_char = 4 },
        .symbol = "proj/settings.zig/load().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    var sym_b = try allocator.alloc(scip.SymbolInformation, 2);
    sym_b[0] = .{
        .symbol = "proj/settings.zig/Settings#",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 49, // struct
        .display_name = "Settings",
        .enclosing_symbol = "",
    };
    sym_b[1] = .{
        .symbol = "proj/settings.zig/load().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "load",
        .enclosing_symbol = "",
    };

    // File C: src/http.zig — defines init (unrelated)
    var occ_c = try allocator.alloc(scip.Occurrence, 1);
    occ_c[0] = .{
        .range = .{ .start_line = 8, .start_char = 0, .end_line = 8, .end_char = 4 },
        .symbol = "proj/http.zig/init().",
        .symbol_roles = scip.SymbolRole.Definition,
        .syntax_kind = 0,
    };

    var sym_c = try allocator.alloc(scip.SymbolInformation, 1);
    sym_c[0] = .{
        .symbol = "proj/http.zig/init().",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 12, // function
        .display_name = "init",
        .enclosing_symbol = "",
    };

    var documents = try allocator.alloc(scip.Document, 3);
    documents[0] = .{
        .language = "zig",
        .relative_path = "src/commands.zig",
        .occurrences = occ_a,
        .symbols = sym_a,
    };
    documents[1] = .{
        .language = "zig",
        .relative_path = "src/settings.zig",
        .occurrences = occ_b,
        .symbols = sym_b,
    };
    documents[2] = .{
        .language = "zig",
        .relative_path = "src/http.zig",
        .occurrences = occ_c,
        .symbols = sym_c,
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "test", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = documents,
        .external_symbols = &.{},
    };

    return try CodeIndex.build(allocator, index);
}

fn deinitTestIndex(ci: *CodeIndex, allocator: std.mem.Allocator) void {
    // Free occurrence and symbol arrays for each document
    for (ci.index.documents) |doc| {
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
    }
    ci.symbol_to_defs.deinit(allocator);
    var ref_iter = ci.symbol_to_refs.iterator();
    while (ref_iter.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    ci.symbol_to_refs.deinit(allocator);
    ci.path_to_doc_idx.deinit(allocator);
    allocator.free(ci.index.documents);
}

test "disambiguateBatch: anchor resolves floater" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [init, Settings]
    // Settings has 1 match (anchor), init has 2 matches (floater)
    var matches_init = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init.deinit(allocator);
    var matches_settings = try ci.findSymbol(allocator, "Settings", null, null);
    defer matches_settings.deinit(allocator);

    // Verify init is ambiguous and Settings is anchor
    try std.testing.expect(matches_init.items.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), matches_settings.items.len);

    var all_matches = [_]CodeIndex.MatchList{ matches_init, matches_settings };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Settings (index 1) should select 0 (only match)
    try std.testing.expectEqual(@as(?usize, 0), selected[1]);

    // init (index 0) should pick the one from commands.zig because it
    // co-occurs with Settings (Settings is referenced in commands.zig)
    const init_idx = selected[0] orelse 0;
    const chosen_init = matches_init.items[init_idx];
    try std.testing.expectEqualStrings("src/commands.zig", chosen_init.def.path);
}

test "disambiguateBatch: all anchors" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [Settings, initBrain] — both unique
    var matches_settings = try ci.findSymbol(allocator, "Settings", null, null);
    defer matches_settings.deinit(allocator);
    var matches_initbrain = try ci.findSymbol(allocator, "initBrain", null, null);
    defer matches_initbrain.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), matches_settings.items.len);
    try std.testing.expectEqual(@as(usize, 1), matches_initbrain.items.len);

    var all_matches = [_]CodeIndex.MatchList{ matches_settings, matches_initbrain };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    try std.testing.expectEqual(@as(?usize, 0), selected[0]);
    try std.testing.expectEqual(@as(?usize, 0), selected[1]);
}

test "disambiguateBatch: all floaters pair-linking" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [init, load] — both ambiguous (init has 2 matches)
    // load has 1 match, but let's verify the pair-linking path works.
    // Since load only has 1 match it's actually an anchor. Let's construct
    // a scenario with truly all-floater queries by using init twice with kind filter off.
    var matches_init = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init.deinit(allocator);

    // Skip if init has fewer than 2 matches
    if (matches_init.items.len < 2) return;

    // Create a second copy of init matches to simulate two floaters
    var matches_init2 = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init2.deinit(allocator);

    var all_matches = [_]CodeIndex.MatchList{ matches_init, matches_init2 };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Both should get a selection (not null)
    try std.testing.expect(selected[0] != null);
    try std.testing.expect(selected[1] != null);
}

test "disambiguateBatch: empty query" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [nonexistent, Settings]
    var matches_none = try ci.findSymbol(allocator, "nonexistent_symbol_xyz", null, null);
    defer matches_none.deinit(allocator);
    var matches_settings = try ci.findSymbol(allocator, "Settings", null, null);
    defer matches_settings.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), matches_none.items.len);

    var all_matches = [_]CodeIndex.MatchList{ matches_none, matches_settings };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Empty query should have null selection
    try std.testing.expectEqual(@as(?usize, null), selected[0]);
    // Settings should select 0
    try std.testing.expectEqual(@as(?usize, 0), selected[1]);
}

test "disambiguateBatch: empty query with floater" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query: [nonexistent, init] — empty + floater combo
    // This exercises the path where the null-to-0 fallback would have
    // incorrectly overwritten the empty query's null selection.
    var matches_none = try ci.findSymbol(allocator, "nonexistent_symbol_xyz", null, null);
    defer matches_none.deinit(allocator);
    var matches_init = try ci.findSymbol(allocator, "init", null, null);
    defer matches_init.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), matches_none.items.len);
    try std.testing.expect(matches_init.items.len >= 2);

    var all_matches = [_]CodeIndex.MatchList{ matches_none, matches_init };
    const selected = try disambiguateBatch(allocator, &ci, &all_matches);
    defer allocator.free(selected);

    // Empty query must remain null even with floaters present
    try std.testing.expectEqual(@as(?usize, null), selected[0]);
    // init should get a selection
    try std.testing.expect(selected[1] != null);
}

test "sameDirectory" {
    try std.testing.expect(sameDirectory("src/foo.zig", "src/bar.zig"));
    try std.testing.expect(!sameDirectory("src/foo.zig", "lib/bar.zig"));
    try std.testing.expect(sameDirectory("foo.zig", "bar.zig")); // both root
}

test "buildFileOccurrenceSet" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // commands.zig should have occurrences for init, initBrain, and Settings reference
    var set = ci.buildFileOccurrenceSet(allocator, "src/commands.zig");
    defer set.deinit(allocator);

    try std.testing.expect(set.contains("proj/commands.zig/init()."));
    try std.testing.expect(set.contains("proj/commands.zig/initBrain()."));
    try std.testing.expect(set.contains("proj/settings.zig/Settings#"));

    // Non-existent file returns empty set
    var empty_set = ci.buildFileOccurrenceSet(allocator, "nonexistent.zig");
    defer empty_set.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), empty_set.count());
}

test "isSymbolInFile" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Settings symbol is referenced in commands.zig
    try std.testing.expect(ci.isSymbolInFile("src/commands.zig", "proj/settings.zig/Settings#"));
    // Settings symbol is NOT referenced in http.zig
    try std.testing.expect(!ci.isSymbolInFile("src/http.zig", "proj/settings.zig/Settings#"));
    // Non-existent file
    try std.testing.expect(!ci.isSymbolInFile("nonexistent.zig", "proj/settings.zig/Settings#"));
}

// ── readDefinitionBody tests ─────────────────────────────────────────────

fn testReadBodyFromContent(allocator: std.mem.Allocator, content: []const u8, def_line: i32, def_end_line: i32, fallback_context: usize) !ReadBodyResult {
    const tmp_path = "/tmp/cog_test_body.zig";
    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer file.close();
    try file.writeAll(content);

    return readDefinitionBody(allocator, "/tmp", "cog_test_body.zig", def_line, def_end_line, fallback_context);
}

test "readDefinitionBody: function with enclosing_range" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\pub fn hello(name: []const u8) void {
        \\    std.debug.print("hello {s}\n", .{name});
        \\}
        \\
        \\pub fn other() void {}
    ;
    // def_line=2, def_end_line=4 (enclosing_range covers lines 2-4)
    const result = try testReadBodyFromContent(allocator, content, 2, 4, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "std.debug.print") != null);
    // Should NOT contain the other function
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn other") == null);
}

test "readDefinitionBody: struct with enclosing_range" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\pub const MyStruct = struct {
        \\    field_a: u32,
        \\    field_b: struct {
        \\        inner: bool,
        \\    },
        \\
        \\    pub fn method(self: *MyStruct) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\const other = 42;
    ;
    // def_line=2, def_end_line=11 (struct body ends at };)
    const result = try testReadBodyFromContent(allocator, content, 2, 11, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub const MyStruct") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn method") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "};") != null);
    // Should NOT contain "const other"
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "const other") == null);
}

test "readDefinitionBody: fallback without enclosing_range" {
    const allocator = std.testing.allocator;
    const content =
        \\const a = 1;
        \\const b = 2;
        \\const target = 42;
        \\const d = 4;
        \\const e = 5;
    ;
    // def_end_line=0 means no enclosing_range — uses fallback_context window
    const result = try testReadBodyFromContent(allocator, content, 2, 0, 2);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "const target = 42;") != null);
}

test "readDefinitionBody: doc comments captured" {
    const allocator = std.testing.allocator;
    const content =
        \\const std = @import("std");
        \\
        \\/// This is a doc comment
        \\/// for the hello function
        \\pub fn hello() void {
        \\    return;
        \\}
    ;
    // def_line=4, def_end_line=6 (function body)
    const result = try testReadBodyFromContent(allocator, content, 4, 6, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "/// This is a doc comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "/// for the hello function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.snippet, "pub fn hello") != null);
}

test "readDefinitionBody: truncation at MAX_BODY_LINES" {
    const allocator = std.testing.allocator;
    // Create content with more than MAX_BODY_LINES
    var content_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer content_buf.deinit(allocator);
    try content_buf.appendSlice(allocator, "pub fn big() void {\n");
    for (0..200) |i| {
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "    _ = {};\n", .{i}) catch unreachable;
        try content_buf.appendSlice(allocator, line);
    }
    try content_buf.appendSlice(allocator, "}\n");

    const tmp_path = "/tmp/cog_test_body.zig";
    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer file.close();
    try file.writeAll(content_buf.items);

    // def_end_line=201 (past MAX_BODY_LINES)
    const result = try readDefinitionBody(allocator, "/tmp", "cog_test_body.zig", 0, 201, 15);
    defer allocator.free(result.snippet);

    try std.testing.expect(result.truncated);
}

// ── discoverRelatedSymbols tests ─────────────────────────────────────────

test "discoverRelatedSymbols: discovers co-file symbols" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Query "init" in commands.zig — should discover initBrain and Settings as related
    var queried_files = std.ArrayListUnmanaged([]const u8){};
    defer queried_files.deinit(allocator);
    try queried_files.append(allocator, "src/commands.zig");

    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);
    try queried_symbols.put(allocator, "proj/commands.zig/init().", {});

    var related = try discoverRelatedSymbols(allocator, &ci, queried_files.items, &queried_symbols, MAX_RELATED);
    defer related.deinit(allocator);

    // Should find at least initBrain (defined in commands.zig) and Settings (referenced)
    try std.testing.expect(related.items.len >= 1);

    // initBrain should be in the results (defined in same file)
    var found_init_brain = false;
    for (related.items) |rel| {
        if (std.mem.eql(u8, rel.symbol, "proj/commands.zig/initBrain().")) {
            found_init_brain = true;
        }
    }
    try std.testing.expect(found_init_brain);
}

test "discoverRelatedSymbols: excludes already-queried symbols" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    var queried_files = std.ArrayListUnmanaged([]const u8){};
    defer queried_files.deinit(allocator);
    try queried_files.append(allocator, "src/commands.zig");

    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);
    // Mark both init AND initBrain as queried
    try queried_symbols.put(allocator, "proj/commands.zig/init().", {});
    try queried_symbols.put(allocator, "proj/commands.zig/initBrain().", {});

    var related = try discoverRelatedSymbols(allocator, &ci, queried_files.items, &queried_symbols, MAX_RELATED);
    defer related.deinit(allocator);

    // initBrain should NOT be in results since it was queried
    for (related.items) |rel| {
        try std.testing.expect(!std.mem.eql(u8, rel.symbol, "proj/commands.zig/initBrain()."));
    }
}

test "discoverRelatedSymbols: respects max_related cap" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    var queried_files = std.ArrayListUnmanaged([]const u8){};
    defer queried_files.deinit(allocator);
    try queried_files.append(allocator, "src/commands.zig");
    try queried_files.append(allocator, "src/settings.zig");
    try queried_files.append(allocator, "src/http.zig");

    var queried_symbols: std.StringHashMapUnmanaged(void) = .empty;
    defer queried_symbols.deinit(allocator);

    // Cap at 1
    var related = try discoverRelatedSymbols(allocator, &ci, queried_files.items, &queried_symbols, 1);
    defer related.deinit(allocator);

    try std.testing.expect(related.items.len <= 1);
}

// ── findReferencesInRange tests ──────────────────────────────────────────

test "findReferencesInRange: finds symbols referenced within range" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // In commands.zig, init is defined at line 5, Settings is referenced at line 10, initBrain at line 20
    // Range 5-15 should find Settings but not initBrain
    var refs = ci.findReferencesInRange(allocator, "src/commands.zig", "proj/commands.zig/init().", 5, 15);
    defer refs.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqualStrings("Settings", refs.items[0]);
}

test "findReferencesInRange: excludes self symbol" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // Range 0-25 covers init (line 5), Settings ref (line 10), initBrain (line 20)
    // Should find Settings and initBrain but NOT init itself
    var refs = ci.findReferencesInRange(allocator, "src/commands.zig", "proj/commands.zig/init().", 0, 25);
    defer refs.deinit(allocator);

    for (refs.items) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "init"));
    }
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
}

test "findReferencesInRange: returns empty for unknown file" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    var refs = ci.findReferencesInRange(allocator, "src/nonexistent.zig", "proj/foo/bar().", 0, 100);
    defer refs.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

// ── Auto-retry tests ─────────────────────────────────────────────────────

test "auto-retry: glob retry finds partial match" {
    const allocator = std.testing.allocator;
    var ci = try buildTestDisambiguationIndex(allocator);
    defer deinitTestIndex(&ci, allocator);

    // "Brain" doesn't match exactly, but "*Brain*" should find initBrain
    var no_match = try ci.findSymbol(allocator, "Brain", null, null);
    defer no_match.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), no_match.items.len);

    var glob_match = try ci.findSymbol(allocator, "*Brain*", null, null);
    defer glob_match.deinit(allocator);
    try std.testing.expect(glob_match.items.len > 0);

    // Verify the found symbol is initBrain
    try std.testing.expect(std.mem.eql(u8, glob_match.items[0].def.display_name, "initBrain"));
}

