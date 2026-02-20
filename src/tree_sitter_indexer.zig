const std = @import("std");
const scip = @import("scip.zig");

// ── Tree-sitter C API ───────────────────────────────────────────────────

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

// ── Language grammars (extern C functions) ───────────────────────────────

extern fn tree_sitter_go() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_typescript() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_tsx() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_javascript() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_python() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_java() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_rust() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_c() callconv(.c) *c.TSLanguage;
extern fn tree_sitter_cpp() callconv(.c) *c.TSLanguage;

// ── Language enum ───────────────────────────────────────────────────────

pub const Language = enum {
    go,
    typescript,
    tsx,
    javascript,
    python,
    java,
    rust,
    c_lang,
    cpp,

    pub fn tsLanguage(self: Language) *c.TSLanguage {
        return switch (self) {
            .go => tree_sitter_go(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
            .javascript => tree_sitter_javascript(),
            .python => tree_sitter_python(),
            .java => tree_sitter_java(),
            .rust => tree_sitter_rust(),
            .c_lang => tree_sitter_c(),
            .cpp => tree_sitter_cpp(),
        };
    }

    pub fn querySource(self: Language) []const u8 {
        return switch (self) {
            .go => @embedFile("queries/go.scm"),
            .typescript => @embedFile("queries/typescript.scm"),
            .tsx => @embedFile("queries/tsx.scm"),
            .javascript => @embedFile("queries/javascript.scm"),
            .python => @embedFile("queries/python.scm"),
            .java => @embedFile("queries/java.scm"),
            .rust => @embedFile("queries/rust.scm"),
            .c_lang => @embedFile("queries/c.scm"),
            .cpp => @embedFile("queries/cpp.scm"),
        };
    }

    pub fn scipName(self: Language) []const u8 {
        return switch (self) {
            .go => "go",
            .typescript => "typescript",
            .tsx => "tsx",
            .javascript => "javascript",
            .python => "python",
            .java => "java",
            .rust => "rust",
            .c_lang => "c",
            .cpp => "cpp",
        };
    }
};

/// Detect language from file extension. Returns null for unsupported extensions.
pub fn detectLanguage(ext: []const u8) ?Language {
    if (ext.len == 0) return null;
    // Strip leading dot if present
    const e = if (ext[0] == '.') ext[1..] else ext;

    if (std.mem.eql(u8, e, "go")) return .go;
    if (std.mem.eql(u8, e, "ts")) return .typescript;
    if (std.mem.eql(u8, e, "tsx")) return .tsx;
    if (std.mem.eql(u8, e, "js")) return .javascript;
    if (std.mem.eql(u8, e, "jsx")) return .javascript;
    if (std.mem.eql(u8, e, "mjs")) return .javascript;
    if (std.mem.eql(u8, e, "cjs")) return .javascript;
    if (std.mem.eql(u8, e, "py")) return .python;
    if (std.mem.eql(u8, e, "pyi")) return .python;
    if (std.mem.eql(u8, e, "java")) return .java;
    if (std.mem.eql(u8, e, "rs")) return .rust;
    if (std.mem.eql(u8, e, "c")) return .c_lang;
    if (std.mem.eql(u8, e, "h")) return .c_lang;
    if (std.mem.eql(u8, e, "cpp")) return .cpp;
    if (std.mem.eql(u8, e, "cc")) return .cpp;
    if (std.mem.eql(u8, e, "cxx")) return .cpp;
    if (std.mem.eql(u8, e, "hpp")) return .cpp;
    if (std.mem.eql(u8, e, "hxx")) return .cpp;
    if (std.mem.eql(u8, e, "hh")) return .cpp;
    return null;
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
        "if",       "else",     "for",       "while",     "do",
        "switch",   "case",     "break",     "continue",  "return",
        "throw",    "try",      "catch",     "finally",   "with",
        "debugger", "delete",   "typeof",    "instanceof","void",
        "in",       "of",       "new",       "yield",     "await",
        "this",     "super",    "null",      "true",      "false",
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

    /// Index a single file and return a document with its backing string data.
    /// The caller owns all allocated memory in the returned result.
    /// `string_data` must be freed separately from the document — it holds
    /// all symbol IDs and display names that the document's slices reference.
    pub fn indexFile(
        self: *Indexer,
        allocator: std.mem.Allocator,
        source: []const u8,
        relative_path: []const u8,
        language: Language,
    ) !IndexFileResult {
        // Detect Flow-typed JS files and use TypeScript parser instead.
        // Flow's generic syntax (<T>) is invalid JS but valid TS, so the
        // TypeScript parser handles these files correctly. We keep the JS
        // query patterns since TS grammar produces the same base node types.
        const is_flow = language == .javascript and isFlowFile(source);
        const parser_lang: Language = if (is_flow) .typescript else language;

        const ts_lang = parser_lang.tsLanguage();

        // Set parser language
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

        // Compile the query — use JS patterns even for Flow files since
        // the TS grammar produces compatible node types
        const query_src = language.querySource();
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
                language.scipName(),
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

        var raw_defs: std.ArrayListUnmanaged(RawDef) = .empty;
        defer raw_defs.deinit(allocator);

        var match: c.TSQueryMatch = undefined;

        while (c.ts_query_cursor_next_match(cursor, &match)) {
            var name_node: ?c.TSNode = null;
            var def_node: ?c.TSNode = null;
            var def_kind: ?i32 = null;

            const captures: [*]const c.TSQueryCapture = match.captures;
            for (0..match.capture_count) |i| {
                const capture = captures[i];
                var name_len: u32 = 0;
                const cap_name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &name_len);
                const cap_name = cap_name_ptr[0..name_len];

                if (std.mem.eql(u8, cap_name, "name")) {
                    name_node = capture.node;
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

            const name_text = source[start_byte..end_byte];

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

        const string_data = try string_buf.toOwnedSlice(allocator);
        errdefer allocator.free(string_data);

        // Phase 3: Build occurrences and symbols using slices into string_data
        var occurrences = try allocator.alloc(scip.Occurrence, raw_defs.items.len);
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
                .enclosing_symbol = "",
            };
        }

        return .{
            .doc = .{
                .language = language.scipName(),
                .relative_path = relative_path,
                .occurrences = occurrences,
                .symbols = symbols,
            },
            .string_data = string_data,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "detectLanguage" {
    try std.testing.expectEqual(Language.go, detectLanguage(".go").?);
    try std.testing.expectEqual(Language.typescript, detectLanguage(".ts").?);
    try std.testing.expectEqual(Language.tsx, detectLanguage(".tsx").?);
    try std.testing.expectEqual(Language.javascript, detectLanguage(".js").?);
    try std.testing.expectEqual(Language.javascript, detectLanguage(".jsx").?);
    try std.testing.expectEqual(Language.javascript, detectLanguage(".mjs").?);
    try std.testing.expectEqual(Language.python, detectLanguage(".py").?);
    try std.testing.expectEqual(Language.java, detectLanguage(".java").?);
    try std.testing.expectEqual(Language.rust, detectLanguage(".rs").?);
    try std.testing.expectEqual(Language.c_lang, detectLanguage(".c").?);
    try std.testing.expectEqual(Language.c_lang, detectLanguage(".h").?);
    try std.testing.expectEqual(Language.cpp, detectLanguage(".cpp").?);
    try std.testing.expectEqual(Language.cpp, detectLanguage(".cc").?);
    try std.testing.expectEqual(Language.cpp, detectLanguage(".hpp").?);
    try std.testing.expect(detectLanguage(".zig") == null);
    try std.testing.expect(detectLanguage(".rb") == null);
    try std.testing.expect(detectLanguage("") == null);
}

test "detectLanguage without dot" {
    try std.testing.expectEqual(Language.go, detectLanguage("go").?);
    try std.testing.expectEqual(Language.python, detectLanguage("py").?);
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

    const result = try indexer.indexFile(allocator, source, "main.go", .go);
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

    const result = try indexer.indexFile(allocator, source, "test.py", .python);
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

    const result = try indexer.indexFile(allocator, source, "test.js", .javascript);
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

test "indexFile empty source" {
    const allocator = std.testing.allocator;
    var indexer = Indexer.init();
    defer indexer.deinit();

    const result = try indexer.indexFile(allocator, "", "empty.go", .go);
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
