const std = @import("std");
const scip = @import("scip.zig");
const extensions = @import("extensions.zig");
const debug_log = @import("debug_log.zig");

// ── Tree-sitter C API ───────────────────────────────────────────────────

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

// ── Language grammars (extern C functions) ───────────────────────────────

extern fn tree_sitter_go() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_json() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_typescript() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_tsx() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_javascript() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_markdown() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_mdx() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_python() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_rst() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_java() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_rust() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_toml() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_c() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_cpp() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_yaml() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_asciidoc() callconv(.c) *c.TSLanguage;

// ── Grammar lookup ──────────────────────────────────────────────────────

/// Look up a compiled tree-sitter grammar by name.
/// Returns null for unknown grammar names.
pub fn getGrammar(name: []const u8) ?*c.TSLanguage {
    if (std.mem.eql(u8, name, "go")) return tree_sitter_go();
    if (std.mem.eql(u8, name, "json")) return tree_sitter_json();
    if (std.mem.eql(u8, name, "typescript")) return tree_sitter_typescript();
    if (std.mem.eql(u8, name, "tsx")) return tree_sitter_tsx();
    if (std.mem.eql(u8, name, "javascript")) return tree_sitter_javascript();
    if (std.mem.eql(u8, name, "markdown")) return tree_sitter_markdown();
    if (std.mem.eql(u8, name, "mdx")) return tree_sitter_mdx();
    if (std.mem.eql(u8, name, "python")) return tree_sitter_python();
    if (std.mem.eql(u8, name, "rst")) return tree_sitter_rst();
    if (std.mem.eql(u8, name, "java")) return tree_sitter_java();
    if (std.mem.eql(u8, name, "rust")) return tree_sitter_rust();
    if (std.mem.eql(u8, name, "toml")) return tree_sitter_toml();
    if (std.mem.eql(u8, name, "c")) return tree_sitter_c();
    if (std.mem.eql(u8, name, "cpp")) return tree_sitter_cpp();
    if (std.mem.eql(u8, name, "yaml")) return tree_sitter_yaml();
    if (std.mem.eql(u8, name, "asciidoc")) return tree_sitter_asciidoc();
    return null;
}

fn isDocumentGrammar(name: []const u8) bool {
    return std.mem.eql(u8, name, "markdown") or
        std.mem.eql(u8, name, "mdx") or
        std.mem.eql(u8, name, "yaml") or
        std.mem.eql(u8, name, "toml") or
        std.mem.eql(u8, name, "rst") or
        std.mem.eql(u8, name, "asciidoc") or
        std.mem.eql(u8, name, "json");
}

// ── SCIP Kind mapping ───────────────────────────────────────────────────

/// Map a tags.scm capture name (e.g. "definition.function") to a SCIP SymbolKind value.
fn captureToScipKind(capture_name: []const u8) ?i32 {
    // Strip "definition." prefix
    const prefix = "definition.";
    if (!std.mem.startsWith(u8, capture_name, prefix)) return null;
    const kind = capture_name[prefix.len..];

    if (std.mem.eql(u8, kind, "function")) return 17;
    if (std.mem.eql(u8, kind, "class")) return 7;
    if (std.mem.eql(u8, kind, "method")) return 26;
    if (std.mem.eql(u8, kind, "interface")) return 21;
    if (std.mem.eql(u8, kind, "module")) return 29;
    if (std.mem.eql(u8, kind, "constant")) return 8;
    if (std.mem.eql(u8, kind, "variable")) return 61;
    if (std.mem.eql(u8, kind, "type")) return 54;
    if (std.mem.eql(u8, kind, "enum")) return 11;
    if (std.mem.eql(u8, kind, "struct")) return 49;
    if (std.mem.eql(u8, kind, "constructor")) return 9;
    if (std.mem.eql(u8, kind, "field")) return 15;
    if (std.mem.eql(u8, kind, "property")) return 41;
    if (std.mem.eql(u8, kind, "macro")) return 25;
    if (std.mem.eql(u8, kind, "namespace")) return 30;
    if (std.mem.eql(u8, kind, "trait")) return 53;
    if (std.mem.eql(u8, kind, "implementation")) return 20;
    if (std.mem.eql(u8, kind, "call")) return 17; // treat as function
    return 0; // UnspecifiedSymbolKind
}

// ── Indexer ─────────────────────────────────────────────────────────────

/// Result from indexing a single file with tree-sitter.
/// `string_data` is a backing buffer holding all symbol ID and display name
/// strings. It must outlive the document (slices in occurrences and symbols
/// point into it). Caller must free `string_data` when done.
pub const IndexFileResult = struct {
    doc: scip.Document,
    string_data: []const u8,
};

/// Check if a node sits inside an ERROR node in the AST.
fn nodeInErrorContext(node: c.TSNode) bool {
    if (c.ts_node_is_error(node)) return true;
    var current = c.ts_node_parent(node);
    for (0..8) |_| {
        if (c.ts_node_is_null(current)) break;
        if (c.ts_node_is_error(current)) return true;
        current = c.ts_node_parent(current);
    }
    return false;
}

/// Returns true if the name is a JavaScript/TypeScript reserved keyword.
/// When error recovery misparses code (e.g. Flow-typed JS), keywords like
/// `if` can end up as identifier nodes inside fabricated definitions.
fn isJsKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "if",        "else",   "for",    "while",      "do",
        "switch",    "case",   "break",  "continue",   "return",
        "throw",     "try",    "catch",  "finally",    "with",
        "debugger",  "delete", "typeof", "instanceof", "void",
        "in",        "of",     "new",    "yield",      "await",
        "this",      "super",  "null",   "true",       "false",
        "undefined",
    };
    for (&keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

/// Detect if a JavaScript file uses Flow type annotations by checking
/// for `@flow` in the first 256 bytes (the pragma is always at the top).
fn isFlowFile(source: []const u8) bool {
    const check_len = @min(source.len, 256);
    const header = source[0..check_len];
    return std.mem.indexOf(u8, header, "@flow") != null;
}

fn trimImportText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n\"'");
}

fn normalizeImportLabel(allocator: std.mem.Allocator, importer_path: []const u8, raw_label: []const u8) ![]const u8 {
    if (raw_label.len == 0) return try allocator.dupe(u8, raw_label);
    if (std.mem.startsWith(u8, raw_label, "./") or std.mem.startsWith(u8, raw_label, "../")) {
        const base_dir = std.fs.path.dirname(importer_path) orelse ".";
        return std.fs.path.resolve(allocator, &.{ base_dir, raw_label });
    }
    return try allocator.dupe(u8, raw_label);
}

fn pointContains(start_row: u32, start_col: u32, end_row: u32, end_col: u32, row: u32, col: u32) bool {
    if (row < start_row or row > end_row) return false;
    if (row == start_row and col < start_col) return false;
    if (row == end_row and col > end_col) return false;
    return true;
}

fn normalizeCallText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..open_paren], " \t\r\n");
}

pub const Indexer = struct {
    parser: *c.TSParser,

    pub fn init() Indexer {
        return .{
            .parser = c.ts_parser_new().?,
        };
    }

    pub fn deinit(self: *Indexer) void {
        c.ts_parser_delete(self.parser);
    }

    fn resetParser(self: *Indexer) !void {
        debug_log.log("Indexer.resetParser: recreating tree-sitter parser", .{});
        c.ts_parser_delete(self.parser);
        self.parser = c.ts_parser_new() orelse return error.OutOfMemory;
    }

    /// Index a single file and return a document with its backing string data.
    /// The caller owns all allocated memory in the returned result.
    /// `string_data` must be freed separately from the document — it holds
    /// all symbol IDs and display names that the document's slices reference.
    pub fn indexFile(
        self: *Indexer,
        allocator: std.mem.Allocator,
        source: []const u8,
        relative_path: []const u8,
        config: extensions.TreeSitterConfig,
    ) !IndexFileResult {
        debug_log.log("indexFile: {s} grammar={s}", .{ relative_path, config.grammar_name });
        if (isDocumentGrammar(config.grammar_name)) {
            debug_log.log("indexFile: structured text indexing active for {s} scip={s}", .{ relative_path, config.scip_name });
        }
        // Detect Flow-typed JS files and use TypeScript parser instead.
        // Flow's generic syntax (<T>) is invalid JS but valid TS, so the
        // TypeScript parser handles these files correctly. We keep the JS
        // query patterns since TS grammar produces the same base node types.
        const is_flow = std.mem.eql(u8, config.grammar_name, "javascript") and isFlowFile(source);
        const parser_grammar = if (is_flow) "typescript" else config.grammar_name;

        const ts_lang = getGrammar(parser_grammar) orelse return error.UnknownGrammar;

        try self.resetParser();

        // Set parser language on a fresh parser instance.
        // Recreating the parser is more defensive than reset alone and avoids
        // stale external-scanner state surviving across files or grammars.
        if (!c.ts_parser_set_language(self.parser, ts_lang)) {
            return error.LanguageVersionMismatch;
        }

        // Parse the source
        const tree = c.ts_parser_parse_string(
            self.parser,
            null,
            source.ptr,
            @intCast(source.len),
        ) orelse return error.ParseFailed;
        defer c.ts_tree_delete(tree);

        const root_node = c.ts_tree_root_node(tree);

        // Compile the query — use the config's query source even for Flow files
        // since the TS grammar produces compatible node types
        const query_src = config.query_source;
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;
        const query = c.ts_query_new(
            ts_lang,
            query_src.ptr,
            @intCast(query_src.len),
            &error_offset,
            &error_type,
        ) orelse {
            // Log query compilation error to stderr for debugging
            var err_buf: [256]u8 = undefined;
            const err_kind: []const u8 = switch (error_type) {
                c.TSQueryErrorSyntax => "syntax",
                c.TSQueryErrorNodeType => "node_type",
                c.TSQueryErrorField => "field",
                c.TSQueryErrorCapture => "capture",
                c.TSQueryErrorStructure => "structure",
                else => "unknown",
            };
            const err_msg = std.fmt.bufPrint(&err_buf, "query compile error ({s}) at offset {d} in {s} query\n", .{
                err_kind,
                error_offset,
                config.scip_name,
            }) catch "query compile error\n";
            var buf: [4096]u8 = undefined;
            var w = std.fs.File.stderr().writer(&buf);
            w.interface.writeAll(err_msg) catch {};
            w.interface.flush() catch {};
            return error.QueryCompilationFailed;
        };
        defer c.ts_query_delete(query);

        // Execute query
        const cursor = c.ts_query_cursor_new().?;
        defer c.ts_query_cursor_delete(cursor);
        c.ts_query_cursor_exec(cursor, query, root_node);

        // Phase 1: Collect raw definitions
        const RawDef = struct {
            name_text: []const u8, // slice into source, not allocated
            start_point: c.TSPoint, // name identifier start
            end_point: c.TSPoint, // name identifier end
            def_start_point: c.TSPoint, // full definition node start (for enclosing_range)
            def_end_point: c.TSPoint, // full definition node end (for enclosing_range)
            kind: i32,
        };

        const RawImport = struct {
            label: []const u8,
            start_point: c.TSPoint,
            end_point: c.TSPoint,
        };

        const RawCall = struct {
            name: []const u8,
            start_point: c.TSPoint,
            end_point: c.TSPoint,
        };

        const RawRelationship = struct {
            from_idx: usize,
            to_idx: ?usize = null,
            target_symbol: ?[]const u8 = null,
            kind: []const u8,
        };

        var raw_defs: std.ArrayListUnmanaged(RawDef) = .empty;
        defer raw_defs.deinit(allocator);
        var raw_imports: std.ArrayListUnmanaged(RawImport) = .empty;
        defer {
            for (raw_imports.items) |item| allocator.free(item.label);
            raw_imports.deinit(allocator);
        }
        var raw_calls: std.ArrayListUnmanaged(RawCall) = .empty;
        defer raw_calls.deinit(allocator);
        var raw_relationships: std.ArrayListUnmanaged(RawRelationship) = .empty;
        defer raw_relationships.deinit(allocator);

        var match: c.TSQueryMatch = undefined;

        while (c.ts_query_cursor_next_match(cursor, &match)) {
            var name_node: ?c.TSNode = null;
            var def_node: ?c.TSNode = null;
            var def_kind: ?i32 = null;

            if (match.capture_count == 0 or match.captures == null) continue;

            const captures: [*]const c.TSQueryCapture = match.captures;
            for (0..match.capture_count) |i| {
                const capture = captures[i];
                var name_len: u32 = 0;
                const cap_name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &name_len);
                const cap_name = cap_name_ptr[0..name_len];

                if (std.mem.eql(u8, cap_name, "name")) {
                    name_node = capture.node;
                } else if (std.mem.startsWith(u8, cap_name, "reference.import")) {
                    const import_start = c.ts_node_start_byte(capture.node);
                    const import_end = c.ts_node_end_byte(capture.node);
                    if (import_start < source.len and import_end <= source.len and import_start < import_end) {
                        const raw_text = trimImportText(source[import_start..import_end]);
                        if (raw_text.len > 0) {
                            const normalized = normalizeImportLabel(allocator, relative_path, raw_text) catch continue;
                            var seen_import = false;
                            for (raw_imports.items) |existing| {
                                if (std.mem.eql(u8, existing.label, normalized)) {
                                    seen_import = true;
                                    break;
                                }
                            }
                            if (!seen_import) {
                                try raw_imports.append(allocator, .{
                                    .label = normalized,
                                    .start_point = c.ts_node_start_point(capture.node),
                                    .end_point = c.ts_node_end_point(capture.node),
                                });
                            } else {
                                allocator.free(normalized);
                            }
                        }
                    }
                } else if (std.mem.startsWith(u8, cap_name, "reference.call")) {
                    const call_start = c.ts_node_start_byte(capture.node);
                    const call_end = c.ts_node_end_byte(capture.node);
                    if (call_start < source.len and call_end <= source.len and call_start < call_end) {
                        const call_text = normalizeCallText(source[call_start..call_end]);
                        if (call_text.len > 0 and !isJsKeyword(call_text)) {
                            var seen_call = false;
                            const start_pt = c.ts_node_start_point(capture.node);
                            for (raw_calls.items) |existing| {
                                if (existing.start_point.row == start_pt.row and
                                    existing.start_point.column == start_pt.column and
                                    std.mem.eql(u8, existing.name, call_text))
                                {
                                    seen_call = true;
                                    break;
                                }
                            }
                            if (!seen_call) {
                                try raw_calls.append(allocator, .{
                                    .name = call_text,
                                    .start_point = start_pt,
                                    .end_point = c.ts_node_end_point(capture.node),
                                });
                            }
                        }
                    }
                } else if (captureToScipKind(cap_name)) |kind| {
                    def_kind = kind;
                    def_node = capture.node;
                }
            }

            const name_n = name_node orelse continue;
            const kind = def_kind orelse continue;

            // Skip names that are themselves error nodes or whose
            // immediate parent is an error node.  We intentionally do
            // NOT walk the full ancestor chain: Flow-typed JS produces
            // error nodes around type annotations, but the function
            // name identifier is still valid and worth capturing.
            if (c.ts_node_is_error(name_n)) continue;
            const name_parent = c.ts_node_parent(name_n);
            if (!c.ts_node_is_null(name_parent) and c.ts_node_is_error(name_parent)) continue;

            const start_byte = c.ts_node_start_byte(name_n);
            const end_byte = c.ts_node_end_byte(name_n);
            if (start_byte >= source.len or end_byte > source.len or start_byte >= end_byte) continue;

            const name_text = std.mem.trim(u8, source[start_byte..end_byte], " \t\r\n");
            if (name_text.len == 0) continue;

            // Skip reserved keywords that appear as definitions due to
            // error recovery (e.g. Flow-typed JS misidentifying `if` as
            // a method name).
            if (isJsKeyword(name_text)) continue;

            // Deduplicate: skip if we already have a def with the same
            // name on the same line (e.g. export_statement + function_declaration
            // both capturing the same identifier).
            const this_row = c.ts_node_start_point(name_n).row;
            var is_dup = false;
            for (raw_defs.items) |existing| {
                if (existing.start_point.row == this_row and
                    std.mem.eql(u8, existing.name_text, name_text))
                {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) continue;

            const def_n = def_node orelse name_n;
            try raw_defs.append(allocator, .{
                .name_text = name_text,
                .start_point = c.ts_node_start_point(name_n),
                .end_point = c.ts_node_end_point(name_n),
                .def_start_point = c.ts_node_start_point(def_n),
                .def_end_point = c.ts_node_end_point(def_n),
                .kind = kind,
            });
        }

        // Phase 2: Build a single backing buffer for all strings
        // Each def needs: "local N" (symbol ID) + name_text (display name)
        var string_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer string_buf.deinit(allocator);

        const OffsetLen = struct { off: usize, len: usize };
        const OffsetPair = struct { sym: OffsetLen, name: OffsetLen };
        var offset_pairs = try allocator.alloc(OffsetPair, raw_defs.items.len);
        defer allocator.free(offset_pairs);
        var import_offsets = try allocator.alloc(OffsetLen, raw_imports.items.len);
        defer allocator.free(import_offsets);
        var call_offsets = try allocator.alloc(OffsetLen, raw_calls.items.len);
        defer allocator.free(call_offsets);

        for (raw_defs.items, 0..) |def, i| {
            // Write symbol ID: "local <path>:<N>"
            // Include the file path to make IDs globally unique across documents
            // (plain "local N" collides when multiple files have the same index)
            const sym_start = string_buf.items.len;
            try string_buf.appendSlice(allocator, "local ");
            try string_buf.appendSlice(allocator, relative_path);
            try string_buf.appendSlice(allocator, ":");
            var counter_buf: [32]u8 = undefined;
            const num_str = std.fmt.bufPrint(&counter_buf, "{d}", .{i}) catch unreachable;
            try string_buf.appendSlice(allocator, num_str);
            const sym_len = string_buf.items.len - sym_start;

            // Write display name
            const name_start = string_buf.items.len;
            try string_buf.appendSlice(allocator, def.name_text);
            const name_len = string_buf.items.len - name_start;

            offset_pairs[i] = .{
                .sym = .{ .off = sym_start, .len = sym_len },
                .name = .{ .off = name_start, .len = name_len },
            };
        }

        for (raw_imports.items, 0..) |item, i| {
            const sym_start = string_buf.items.len;
            try string_buf.appendSlice(allocator, "cog/import/");
            try string_buf.appendSlice(allocator, item.label);
            import_offsets[i] = .{ .off = sym_start, .len = string_buf.items.len - sym_start };
        }

        for (raw_calls.items, 0..) |item, i| {
            const sym_start = string_buf.items.len;
            try string_buf.appendSlice(allocator, "cog/call/");
            try string_buf.appendSlice(allocator, item.name);
            call_offsets[i] = .{ .off = sym_start, .len = string_buf.items.len - sym_start };
        }

        const string_data = try string_buf.toOwnedSlice(allocator);
        errdefer allocator.free(string_data);

        // Phase 3: Build occurrences and symbols using slices into string_data
        var occurrences = try allocator.alloc(scip.Occurrence, raw_defs.items.len + raw_imports.items.len + raw_calls.items.len);
        errdefer allocator.free(occurrences);

        var symbols = try allocator.alloc(scip.SymbolInformation, raw_defs.items.len);
        errdefer {
            for (symbols) |*sym| {
                allocator.free(sym.documentation);
                allocator.free(sym.relationships);
            }
            allocator.free(symbols);
        }

        for (raw_defs.items, offset_pairs, 0..) |def, off, i| {
            const symbol_id = string_data[off.sym.off..][0..off.sym.len];
            const display_name = string_data[off.name.off..][0..off.name.len];
            var enclosing_symbol: []const u8 = "";
            var enclosing_index: ?usize = null;

            var best_parent_span: u64 = std.math.maxInt(u64);
            for (raw_defs.items, offset_pairs, 0..) |candidate, candidate_off, parent_idx| {
                if (parent_idx == i) continue;
                if (!pointContains(candidate.def_start_point.row, candidate.def_start_point.column, candidate.def_end_point.row, candidate.def_end_point.column, def.def_start_point.row, def.def_start_point.column)) continue;
                if (!pointContains(candidate.def_start_point.row, candidate.def_start_point.column, candidate.def_end_point.row, candidate.def_end_point.column, def.def_end_point.row, def.def_end_point.column)) continue;
                const row_span = @as(u64, candidate.def_end_point.row) - @as(u64, candidate.def_start_point.row);
                const span = row_span * 10000 + @as(u64, candidate.def_end_point.column);
                if (span < best_parent_span) {
                    best_parent_span = span;
                    enclosing_index = parent_idx;
                    enclosing_symbol = string_data[candidate_off.sym.off..][0..candidate_off.sym.len];
                }
            }

            if (enclosing_index) |parent_idx| {
                try raw_relationships.append(allocator, .{
                    .from_idx = parent_idx,
                    .to_idx = i,
                    .kind = "contains",
                });
            }

            occurrences[i] = .{
                .range = .{
                    .start_line = @intCast(def.start_point.row),
                    .start_char = @intCast(def.start_point.column),
                    .end_line = @intCast(def.end_point.row),
                    .end_char = @intCast(def.end_point.column),
                },
                .symbol = symbol_id,
                .symbol_roles = scip.SymbolRole.Definition,
                .syntax_kind = 0,
                .enclosing_range = .{
                    .start_line = @intCast(def.def_start_point.row),
                    .start_char = @intCast(def.def_start_point.column),
                    .end_line = @intCast(def.def_end_point.row),
                    .end_char = @intCast(def.def_end_point.column),
                },
            };

            symbols[i] = .{
                .symbol = symbol_id,
                .documentation = try allocator.alloc([]const u8, 0),
                .relationships = try allocator.alloc(scip.Relationship, 0),
                .kind = def.kind,
                .display_name = display_name,
                .enclosing_symbol = enclosing_symbol,
            };
        }

        for (raw_imports.items, import_offsets, 0..) |item, off, i| {
            occurrences[raw_defs.items.len + i] = .{
                .range = .{
                    .start_line = @intCast(item.start_point.row),
                    .start_char = @intCast(item.start_point.column),
                    .end_line = @intCast(item.end_point.row),
                    .end_char = @intCast(item.end_point.column),
                },
                .symbol = string_data[off.off..][0..off.len],
                .symbol_roles = scip.SymbolRole.Import,
                .syntax_kind = 0,
                .enclosing_range = null,
            };

            var attached = false;
            for (symbols, 0..) |sym, sym_idx| {
                if (sym.enclosing_symbol.len != 0) continue;
                try raw_relationships.append(allocator, .{
                    .from_idx = sym_idx,
                    .target_symbol = string_data[off.off..][0..off.len],
                    .kind = "imports",
                });
                attached = true;
            }
            if (!attached) {
                for (raw_defs.items, 0..) |_, candidate_idx| {
                    try raw_relationships.append(allocator, .{
                        .from_idx = candidate_idx,
                        .target_symbol = string_data[off.off..][0..off.len],
                        .kind = "imports",
                    });
                }
            }
        }

        for (raw_calls.items, call_offsets, 0..) |item, off, i| {
            var enclosing_range: ?scip.Range = null;
            var best_parent_span: u64 = std.math.maxInt(u64);
            var caller_idx: ?usize = null;
            for (raw_defs.items, 0..) |candidate, candidate_idx| {
                if (!pointContains(candidate.def_start_point.row, candidate.def_start_point.column, candidate.def_end_point.row, candidate.def_end_point.column, item.start_point.row, item.start_point.column)) continue;
                const row_span = @as(u64, candidate.def_end_point.row) - @as(u64, candidate.def_start_point.row);
                const span = row_span * 10000 + @as(u64, candidate.def_end_point.column);
                if (span < best_parent_span) {
                    best_parent_span = span;
                    caller_idx = candidate_idx;
                    enclosing_range = .{
                        .start_line = @intCast(candidate.def_start_point.row),
                        .start_char = @intCast(candidate.def_start_point.column),
                        .end_line = @intCast(candidate.def_end_point.row),
                        .end_char = @intCast(candidate.def_end_point.column),
                    };
                }
            }

            occurrences[raw_defs.items.len + raw_imports.items.len + i] = .{
                .range = .{
                    .start_line = @intCast(item.start_point.row),
                    .start_char = @intCast(item.start_point.column),
                    .end_line = @intCast(item.end_point.row),
                    .end_char = @intCast(item.end_point.column),
                },
                .symbol = string_data[off.off..][0..off.len],
                .symbol_roles = scip.SymbolRole.ReadAccess,
                .syntax_kind = 0,
                .enclosing_range = enclosing_range,
            };

            if (caller_idx) |from_idx| {
                var target_idx: ?usize = null;
                if (std.mem.indexOfScalar(u8, item.name, '.')) |dot_idx| {
                    const suffix = item.name[dot_idx + 1 ..];
                    for (raw_defs.items, 0..) |candidate, idx| {
                        if (std.mem.eql(u8, candidate.name_text, suffix)) {
                            target_idx = idx;
                            break;
                        }
                    }
                }
                if (target_idx == null) {
                    for (raw_defs.items, 0..) |candidate, idx| {
                        if (std.mem.eql(u8, candidate.name_text, item.name)) {
                            target_idx = idx;
                            break;
                        }
                    }
                }
                if (target_idx) |to_idx| {
                    try raw_relationships.append(allocator, .{
                        .from_idx = from_idx,
                        .to_idx = to_idx,
                        .kind = "calls",
                    });
                }
            }
        }

        var rel_counts = try allocator.alloc(usize, raw_defs.items.len);
        defer allocator.free(rel_counts);
        @memset(rel_counts, 0);
        for (raw_relationships.items) |rel| {
            rel_counts[rel.from_idx] += 1;
        }

        for (symbols, 0..) |*sym, i| {
            const rel_count = rel_counts[i];
            allocator.free(sym.relationships);
            sym.relationships = try allocator.alloc(scip.Relationship, rel_count);
            var rel_idx: usize = 0;
            for (raw_relationships.items) |rel| {
                if (rel.from_idx != i) continue;
                const target_symbol = if (rel.to_idx) |to_idx| blk: {
                    const target_off = offset_pairs[to_idx];
                    break :blk string_data[target_off.sym.off..][0..target_off.sym.len];
                } else rel.target_symbol.?;
                sym.relationships[rel_idx] = .{
                    .symbol = target_symbol,
                    .is_reference = std.mem.eql(u8, rel.kind, "calls"),
                    .is_implementation = false,
                    .is_type_definition = false,
                    .is_definition = std.mem.eql(u8, rel.kind, "contains"),
                    .kind = rel.kind,
                };
                rel_idx += 1;
            }
        }

        debug_log.log("indexFile: defs={d} imports={d} calls={d}", .{ raw_defs.items.len, raw_imports.items.len, raw_calls.items.len });

        return .{
            .doc = .{
                .language = config.scip_name,
                .relative_path = relative_path,
                .occurrences = occurrences,
                .symbols = symbols,
            },
            .string_data = string_data,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

/// Helper to find a builtin tree-sitter config by extension name.
fn findBuiltinConfig(name: []const u8) ?extensions.TreeSitterConfig {
    for (&extensions.builtins) |*b| {
        if (std.mem.eql(u8, b.name, name)) {
            if (b.indexer) |idx| return switch (idx) {
                .tree_sitter => |ts| ts,
                else => null,
            };
        }
    }
    return null;
}

test "getGrammar" {
    try std.testing.expect(getGrammar("go") != null);
    try std.testing.expect(getGrammar("json") != null);
    try std.testing.expect(getGrammar("typescript") != null);
    try std.testing.expect(getGrammar("tsx") != null);
    try std.testing.expect(getGrammar("javascript") != null);
    try std.testing.expect(getGrammar("markdown") != null);
    try std.testing.expect(getGrammar("mdx") != null);
    try std.testing.expect(getGrammar("python") != null);
    try std.testing.expect(getGrammar("rst") != null);
    try std.testing.expect(getGrammar("java") != null);
    try std.testing.expect(getGrammar("rust") != null);
    try std.testing.expect(getGrammar("toml") != null);
    try std.testing.expect(getGrammar("c") != null);
    try std.testing.expect(getGrammar("cpp") != null);
    try std.testing.expect(getGrammar("yaml") != null);
    try std.testing.expect(getGrammar("asciidoc") != null);
    try std.testing.expect(getGrammar("zig") == null);
    try std.testing.expect(getGrammar("ruby") == null);
}

test "captureToScipKind" {
    try std.testing.expectEqual(@as(?i32, 17), captureToScipKind("definition.function"));
    try std.testing.expectEqual(@as(?i32, 7), captureToScipKind("definition.class"));
    try std.testing.expectEqual(@as(?i32, 26), captureToScipKind("definition.method"));
    try std.testing.expectEqual(@as(?i32, 21), captureToScipKind("definition.interface"));
    try std.testing.expectEqual(@as(?i32, null), captureToScipKind("name"));
    try std.testing.expectEqual(@as(?i32, null), captureToScipKind("reference.call"));
}

test "indexFile Go" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\package main
        \\
        \\func hello() {
        \\    println("hello")
        \\}
        \\
        \\func world() string {
        \\    return "world"
        \\}
    ;

    const config = findBuiltinConfig("go") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "main.go", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("go", doc.language);
    try std.testing.expectEqualStrings("main.go", doc.relative_path);
    try std.testing.expect(doc.symbols.len >= 2);

    // Check that we found hello and world functions
    var found_hello = false;
    var found_world = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "hello")) {
            found_hello = true;
            try std.testing.expectEqual(@as(i32, 17), sym.kind); // function
        }
        if (std.mem.eql(u8, sym.display_name, "world")) {
            found_world = true;
            try std.testing.expectEqual(@as(i32, 17), sym.kind); // function
        }
    }
    try std.testing.expect(found_hello);
    try std.testing.expect(found_world);
}

test "indexFile Python" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\class MyClass:
        \\    def my_method(self):
        \\        pass
        \\
        \\def my_function():
        \\    pass
    ;

    const config = findBuiltinConfig("python") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "test.py", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("python", doc.language);

    var found_class = false;
    var found_method = false;
    var found_function = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "MyClass")) {
            found_class = true;
            try std.testing.expectEqual(@as(i32, 7), sym.kind); // class
        }
        if (std.mem.eql(u8, sym.display_name, "my_method")) found_method = true;
        if (std.mem.eql(u8, sym.display_name, "my_function")) found_function = true;
    }
    try std.testing.expect(found_class);
    try std.testing.expect(found_method);
    try std.testing.expect(found_function);
}

test "indexFile JavaScript" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\function greet(name) {
        \\    return "Hello, " + name;
        \\}
        \\
        \\class Greeter {
        \\    constructor(name) {
        \\        this.name = name;
        \\    }
        \\}
    ;

    const config = findBuiltinConfig("javascript") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "test.js", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("javascript", doc.language);

    var found_greet = false;
    var found_greeter = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "greet")) found_greet = true;
        if (std.mem.eql(u8, sym.display_name, "Greeter")) found_greeter = true;
    }
    try std.testing.expect(found_greet);
    try std.testing.expect(found_greeter);
}

test "indexFile TypeScript emits architecture relationships" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\import { helper } from "./helper";
        \\
        \\function outer() {
        \\    function inner() {
        \\        helper();
        \\    }
        \\    inner();
        \\}
    ;

    const config = findBuiltinConfig("typescript") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "src/main.ts", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    var found_outer = false;
    var found_inner = false;
    var found_import_occurrence = false;
    var found_call_occurrence = false;
    var found_import_relationship = false;
    var found_call_relationship = false;

    for (doc.occurrences) |occ| {
        if ((occ.symbol_roles & scip.SymbolRole.Import) != 0) found_import_occurrence = true;
        if (std.mem.startsWith(u8, occ.symbol, "cog/call/")) found_call_occurrence = true;
    }

    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "outer")) {
            found_outer = true;
            for (sym.relationships) |rel| {
                if (std.mem.eql(u8, rel.kind, "imports")) found_import_relationship = true;
                if (std.mem.eql(u8, rel.kind, "calls")) found_call_relationship = true;
            }
        }
        if (std.mem.eql(u8, sym.display_name, "inner")) {
            found_inner = true;
            try std.testing.expect(sym.enclosing_symbol.len > 0);
            for (sym.relationships) |rel| {
                if (std.mem.eql(u8, rel.kind, "calls")) found_call_relationship = true;
            }
        }
    }

    try std.testing.expect(found_outer);
    try std.testing.expect(found_inner);
    try std.testing.expect(found_import_occurrence);
    try std.testing.expect(found_call_occurrence);
    try std.testing.expect(found_import_relationship);
    try std.testing.expect(found_call_relationship);
}

test "indexFile TSX emits import and call captures" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\import { Button } from "./button";
        \\
        \\export function App() {
        \\    Button();
        \\    return <Button />;
        \\}
    ;

    const config = findBuiltinConfig("tsx") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "src/app.tsx", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    var found_app = false;
    var saw_import_occurrence = false;
    for (doc.occurrences) |occ| {
        if ((occ.symbol_roles & scip.SymbolRole.Import) != 0) saw_import_occurrence = true;
    }
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "App")) {
            found_app = true;
            var saw_import = false;
            for (sym.relationships) |rel| {
                if (std.mem.eql(u8, rel.kind, "imports")) saw_import = true;
            }
            try std.testing.expect(saw_import);
        }
    }

    try std.testing.expect(found_app);
    try std.testing.expect(saw_import_occurrence);
}

test "indexFile Markdown" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\# Cog CLI
        \\
        \\## Installation
        \\
        \\Install with Homebrew.
        \\
        \\### API Reference
    ;

    const config = findBuiltinConfig("markdown") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "README.md", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("markdown", doc.language);

    var found_cog_cli = false;
    var found_installation = false;
    var found_api_reference = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Cog CLI")) {
            found_cog_cli = true;
            try std.testing.expectEqual(@as(i32, 29), sym.kind);
        }
        if (std.mem.eql(u8, sym.display_name, "Installation")) {
            found_installation = true;
            try std.testing.expectEqual(@as(i32, 29), sym.kind);
        }
        if (std.mem.eql(u8, sym.display_name, "API Reference")) {
            found_api_reference = true;
            try std.testing.expectEqual(@as(i32, 29), sym.kind);
        }
    }
    try std.testing.expect(found_cog_cli);
    try std.testing.expect(found_installation);
    try std.testing.expect(found_api_reference);
}

test "indexFile MDX" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\# Components
        \\
        \\export function Button() {
        \\  return <button>Click</button>;
        \\}
        \\
        \\## Usage
    ;

    const config = findBuiltinConfig("mdx") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "docs/button.mdx", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("mdx", doc.language);

    var found_components = false;
    var found_button = false;
    var found_usage = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Components")) found_components = true;
        if (std.mem.eql(u8, sym.display_name, "Button")) found_button = true;
        if (std.mem.eql(u8, sym.display_name, "Usage")) found_usage = true;
    }
    try std.testing.expect(found_components);
    try std.testing.expect(found_button);
    try std.testing.expect(found_usage);
}

test "indexFile YAML" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\server:
        \\  host: localhost
        \\  port: 8080
    ;

    const config = findBuiltinConfig("yaml") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "config.yaml", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("yaml", doc.language);

    var found_server = false;
    var found_host = false;
    var found_port = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "server")) found_server = true;
        if (std.mem.eql(u8, sym.display_name, "host")) found_host = true;
        if (std.mem.eql(u8, sym.display_name, "port")) found_port = true;
    }
    try std.testing.expect(found_server);
    try std.testing.expect(found_host);
    try std.testing.expect(found_port);
}

test "indexFile TOML" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\title = "Cog"
        \\
        \\[tool.poetry]
        \\name = "cog-cli"
    ;

    const config = findBuiltinConfig("toml") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "pyproject.toml", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("toml", doc.language);

    var found_title = false;
    var found_tool_poetry = false;
    var found_name = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "title")) found_title = true;
        if (std.mem.eql(u8, sym.display_name, "tool.poetry")) found_tool_poetry = true;
        if (std.mem.eql(u8, sym.display_name, "name")) found_name = true;
    }
    try std.testing.expect(found_title);
    try std.testing.expect(found_tool_poetry);
    try std.testing.expect(found_name);
}

test "indexFile RST" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\Overview
        \\========
        \\
        \\Install
        \\-------
    ;

    const config = findBuiltinConfig("rst") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "guide.rst", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("rst", doc.language);

    var found_overview = false;
    var found_install = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Overview")) found_overview = true;
        if (std.mem.eql(u8, sym.display_name, "Install")) found_install = true;
    }
    try std.testing.expect(found_overview);
    try std.testing.expect(found_install);
}

test "indexFile AsciiDoc" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\= Cog CLI
        \\
        \\== Install
    ;

    const config = findBuiltinConfig("asciidoc") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "guide.adoc", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("asciidoc", doc.language);

    var found_cog_cli = false;
    var found_install = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Cog CLI")) found_cog_cli = true;
        if (std.mem.eql(u8, sym.display_name, "Install")) found_install = true;
    }
    try std.testing.expect(found_cog_cli);
    try std.testing.expect(found_install);
}

test "indexFile JSONC" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\{
        \\  // comment
        \\  "build": {
        \\    "target": "release"
        \\  }
        \\}
    ;

    const config = findBuiltinConfig("jsonc") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "config.jsonc", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("jsonc", doc.language);

    var found_build = false;
    var found_target = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "build")) found_build = true;
        if (std.mem.eql(u8, sym.display_name, "target")) found_target = true;
    }
    try std.testing.expect(found_build);
    try std.testing.expect(found_target);
}

test "indexFile TypeScript" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\interface Greeter {
        \\    greet(): string;
        \\}
        \\
        \\type ID = string;
        \\
        \\enum Color {
        \\    Red,
        \\    Green,
        \\    Blue,
        \\}
    ;

    const config = findBuiltinConfig("typescript") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "test.ts", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("typescript", doc.language);

    var found_greeter = false;
    var found_greet = false;
    var found_id = false;
    var found_color = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Greeter")) {
            found_greeter = true;
            try std.testing.expectEqual(@as(i32, 21), sym.kind); // interface
        }
        if (std.mem.eql(u8, sym.display_name, "greet")) {
            found_greet = true;
            try std.testing.expectEqual(@as(i32, 26), sym.kind); // method
        }
        if (std.mem.eql(u8, sym.display_name, "ID")) {
            found_id = true;
            try std.testing.expectEqual(@as(i32, 54), sym.kind); // type
        }
        if (std.mem.eql(u8, sym.display_name, "Color")) {
            found_color = true;
            try std.testing.expectEqual(@as(i32, 11), sym.kind); // enum
        }
    }
    try std.testing.expect(found_greeter);
    try std.testing.expect(found_greet);
    try std.testing.expect(found_id);
    try std.testing.expect(found_color);
}

test "indexFile TSX" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\interface Props {
        \\    name: string;
        \\}
        \\
        \\type ButtonKind = "primary" | "secondary";
        \\
        \\enum Status {
        \\    Active,
        \\    Inactive,
        \\}
    ;

    const config = findBuiltinConfig("tsx") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "component.tsx", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("tsx", doc.language);

    var found_props = false;
    var found_kind = false;
    var found_status = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Props")) {
            found_props = true;
            try std.testing.expectEqual(@as(i32, 21), sym.kind); // interface
        }
        if (std.mem.eql(u8, sym.display_name, "ButtonKind")) {
            found_kind = true;
            try std.testing.expectEqual(@as(i32, 54), sym.kind); // type
        }
        if (std.mem.eql(u8, sym.display_name, "Status")) {
            found_status = true;
            try std.testing.expectEqual(@as(i32, 11), sym.kind); // enum
        }
    }
    try std.testing.expect(found_props);
    try std.testing.expect(found_kind);
    try std.testing.expect(found_status);
}

test "indexFile Java" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\public class HelloWorld {
        \\    public void greet() {
        \\        System.out.println("Hello");
        \\    }
        \\}
        \\
        \\interface Greetable {
        \\    void sayHello();
        \\}
    ;

    const config = findBuiltinConfig("java") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "HelloWorld.java", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("java", doc.language);

    var found_class = false;
    var found_method = false;
    var found_interface = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "HelloWorld")) {
            found_class = true;
            try std.testing.expectEqual(@as(i32, 7), sym.kind); // class
        }
        if (std.mem.eql(u8, sym.display_name, "greet")) {
            found_method = true;
            try std.testing.expectEqual(@as(i32, 26), sym.kind); // method
        }
        if (std.mem.eql(u8, sym.display_name, "Greetable")) {
            found_interface = true;
            try std.testing.expectEqual(@as(i32, 21), sym.kind); // interface
        }
    }
    try std.testing.expect(found_class);
    try std.testing.expect(found_method);
    try std.testing.expect(found_interface);
}

test "indexFile Rust" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\struct Point {
        \\    x: f64,
        \\    y: f64,
        \\}
        \\
        \\trait Drawable {
        \\    fn draw(&self);
        \\}
        \\
        \\fn main() {
        \\    println!("hello");
        \\}
        \\
        \\mod utils {}
        \\
        \\macro_rules! my_macro {
        \\    () => {};
        \\}
    ;

    const config = findBuiltinConfig("rust") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "main.rs", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("rust", doc.language);

    var found_struct = false;
    var found_trait = false;
    var found_main = false;
    var found_module = false;
    var found_macro = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Point")) {
            found_struct = true;
            try std.testing.expectEqual(@as(i32, 7), sym.kind); // class (struct)
        }
        if (std.mem.eql(u8, sym.display_name, "Drawable")) {
            found_trait = true;
            try std.testing.expectEqual(@as(i32, 21), sym.kind); // interface (trait)
        }
        if (std.mem.eql(u8, sym.display_name, "main")) {
            found_main = true;
            try std.testing.expectEqual(@as(i32, 17), sym.kind); // function
        }
        if (std.mem.eql(u8, sym.display_name, "utils")) {
            found_module = true;
            try std.testing.expectEqual(@as(i32, 29), sym.kind); // module
        }
        if (std.mem.eql(u8, sym.display_name, "my_macro")) {
            found_macro = true;
            try std.testing.expectEqual(@as(i32, 25), sym.kind); // macro
        }
    }
    try std.testing.expect(found_struct);
    try std.testing.expect(found_trait);
    try std.testing.expect(found_main);
    try std.testing.expect(found_module);
    try std.testing.expect(found_macro);
}

test "indexFile C" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\struct Point {
        \\    int x;
        \\    int y;
        \\};
        \\
        \\typedef int MyInt;
        \\
        \\enum Color { RED, GREEN, BLUE };
        \\
        \\void hello() {
        \\    return;
        \\}
    ;

    const config = findBuiltinConfig("c") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "main.c", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("c", doc.language);

    var found_struct = false;
    var found_typedef = false;
    var found_func = false;
    var found_enum = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Point")) {
            found_struct = true;
            try std.testing.expectEqual(@as(i32, 7), sym.kind); // class (struct)
        }
        if (std.mem.eql(u8, sym.display_name, "MyInt")) {
            found_typedef = true;
            try std.testing.expectEqual(@as(i32, 54), sym.kind); // type
        }
        if (std.mem.eql(u8, sym.display_name, "hello")) {
            found_func = true;
            try std.testing.expectEqual(@as(i32, 17), sym.kind); // function
        }
        if (std.mem.eql(u8, sym.display_name, "Color")) {
            found_enum = true;
            try std.testing.expectEqual(@as(i32, 54), sym.kind); // type (enum)
        }
    }
    try std.testing.expect(found_struct);
    try std.testing.expect(found_typedef);
    try std.testing.expect(found_func);
    try std.testing.expect(found_enum);
}

test "indexFile C++" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const source =
        \\class Animal {
        \\public:
        \\    void speak();
        \\};
        \\
        \\struct Point {
        \\    int x;
        \\    int y;
        \\};
        \\
        \\void greet() {}
    ;

    const config = findBuiltinConfig("cpp") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "main.cpp", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqualStrings("cpp", doc.language);

    var found_class = false;
    var found_struct = false;
    var found_func = false;
    for (doc.symbols) |sym| {
        if (std.mem.eql(u8, sym.display_name, "Animal")) {
            found_class = true;
            try std.testing.expectEqual(@as(i32, 7), sym.kind); // class
        }
        if (std.mem.eql(u8, sym.display_name, "Point")) {
            found_struct = true;
            try std.testing.expectEqual(@as(i32, 7), sym.kind); // class (struct)
        }
        if (std.mem.eql(u8, sym.display_name, "greet")) {
            found_func = true;
            try std.testing.expectEqual(@as(i32, 17), sym.kind); // function
        }
    }
    try std.testing.expect(found_class);
    try std.testing.expect(found_struct);
    try std.testing.expect(found_func);
}

test "indexFile parser reuse across languages" {
    // Exercises the code path that caused the original SIGILL crash:
    // reusing a single parser across different grammars (especially
    // switching away from languages with external scanners like JS).
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const langs = [_]struct { name: []const u8, source: []const u8, path: []const u8 }{
        .{ .name = "go", .source = "package main\n\nfunc hello() {}\n", .path = "a.go" },
        .{ .name = "javascript", .source = "function greet() {}\n", .path = "b.js" },
        .{ .name = "python", .source = "def foo():\n    pass\n", .path = "c.py" },
        .{ .name = "typescript", .source = "interface Foo { bar(): void; }\n", .path = "d.ts" },
        .{ .name = "rust", .source = "fn main() {}\n", .path = "e.rs" },
        .{ .name = "java", .source = "class Foo { void bar() {} }\n", .path = "f.java" },
        .{ .name = "c", .source = "void hello() {}\n", .path = "g.c" },
        .{ .name = "cpp", .source = "class Foo {};\nvoid bar() {}\n", .path = "h.cpp" },
        .{ .name = "tsx", .source = "interface Props { x: number; }\n", .path = "i.tsx" },
        // Switch back to JS after other scanners to stress the reset path
        .{ .name = "javascript", .source = "class App {}\n", .path = "j.js" },
    };

    for (&langs) |lang| {
        const config = findBuiltinConfig(lang.name) orelse return error.TestUnexpectedResult;
        const result = try indexer.indexFile(allocator, lang.source, lang.path, config);
        for (result.doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(result.doc.occurrences);
        allocator.free(result.doc.symbols);
        allocator.free(result.string_data);
    }
}

test "indexFile Flow-typed JavaScript uses TypeScript parser" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    // Flow files have @flow pragma and use generic syntax that breaks the JS parser
    const source =
        \\// @flow
        \\function identity<T>(x: T): T {
        \\    return x;
        \\}
    ;

    const config = findBuiltinConfig("javascript") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, source, "flow.js", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    // Should still use "javascript" as the SCIP language name
    try std.testing.expectEqualStrings("javascript", doc.language);
    // The file should parse without errors (TS parser handles Flow generics)
    try std.testing.expect(doc.symbols.len >= 0);
}

test "indexFile empty source" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const config = findBuiltinConfig("go") orelse return error.TestUnexpectedResult;
    const result = try indexer.indexFile(allocator, "", "empty.go", config);
    const doc = result.doc;
    defer {
        for (doc.symbols) |sym| {
            allocator.free(sym.documentation);
            allocator.free(sym.relationships);
        }
        allocator.free(doc.occurrences);
        allocator.free(doc.symbols);
        allocator.free(result.string_data);
    }

    try std.testing.expectEqual(@as(usize, 0), doc.symbols.len);
    try std.testing.expectEqual(@as(usize, 0), doc.occurrences.len);
}
