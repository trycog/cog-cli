const std = @import("std");
const protobuf = @import("protobuf.zig");
const Decoder = protobuf.Decoder;

// ── Types ───────────────────────────────────────────────────────────────

pub const Range = struct {
    start_line: i32,
    start_char: i32,
    end_line: i32,
    end_char: i32,
};

pub const Relationship = struct {
    symbol: []const u8,
    is_reference: bool,
    is_implementation: bool,
    is_type_definition: bool,
    is_definition: bool,
};

pub const SymbolRole = struct {
    pub const Definition: i32 = 0x1;
    pub const Import: i32 = 0x2;
    pub const WriteAccess: i32 = 0x4;
    pub const ReadAccess: i32 = 0x8;

    pub fn isDefinition(roles: i32) bool {
        return (roles & Definition) != 0;
    }

    pub fn describe(roles: i32) []const u8 {
        if (isDefinition(roles)) return "definition";
        if ((roles & Import) != 0) return "import";
        if ((roles & WriteAccess) != 0) return "write";
        if ((roles & ReadAccess) != 0) return "read";
        return "reference";
    }
};

pub const Occurrence = struct {
    range: Range,
    symbol: []const u8,
    symbol_roles: i32,
    syntax_kind: i32,
    enclosing_range: ?Range = null,
};

pub const SymbolInformation = struct {
    symbol: []const u8,
    documentation: []const []const u8,
    relationships: []Relationship,
    kind: i32,
    display_name: []const u8,
    enclosing_symbol: []const u8,
};

pub const Document = struct {
    language: []const u8,
    relative_path: []const u8,
    occurrences: []Occurrence,
    symbols: []SymbolInformation,
};

pub const ToolInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const Metadata = struct {
    version: i32,
    tool_info: ToolInfo,
    project_root: []const u8,
    text_document_encoding: i32,
};

pub const Index = struct {
    metadata: Metadata,
    documents: []Document,
    external_symbols: []SymbolInformation,
};

// ── Symbol Kind names ───────────────────────────────────────────────────

pub fn kindName(kind: i32) []const u8 {
    return switch (kind) {
        1 => "array",
        2 => "assertion",
        3 => "associated_type",
        4 => "attribute",
        5 => "axiom",
        6 => "boolean",
        7 => "class",
        8 => "constant",
        9 => "constructor",
        10 => "data_family",
        11 => "enum",
        12 => "enum_member",
        13 => "event",
        14 => "fact",
        15 => "field",
        16 => "file",
        17 => "function",
        18 => "getter",
        19 => "grammar",
        20 => "instance",
        21 => "interface",
        22 => "key",
        23 => "lang",
        24 => "lemma",
        25 => "macro",
        26 => "method",
        27 => "method_receiver",
        28 => "message",
        29 => "module",
        30 => "namespace",
        31 => "null",
        32 => "number",
        33 => "object",
        34 => "operator",
        35 => "package",
        36 => "package_object",
        37 => "parameter",
        38 => "parameter_label",
        39 => "pattern",
        40 => "predicate",
        41 => "property",
        42 => "protocol",
        43 => "quasiquoter",
        44 => "self_parameter",
        45 => "setter",
        46 => "signature",
        47 => "subscript",
        48 => "string",
        49 => "struct",
        50 => "tactic",
        51 => "theorem",
        52 => "this_parameter",
        53 => "trait",
        54 => "type",
        55 => "type_alias",
        56 => "type_class",
        57 => "type_family",
        58 => "type_parameter",
        59 => "union",
        60 => "value",
        61 => "variable",
        62 => "contract",
        63 => "error",
        64 => "library",
        65 => "modifier",
        66 => "abstract_method",
        67 => "method_specification",
        68 => "protocol_method",
        69 => "pure_virtual_method",
        70 => "trait_method",
        71 => "type_class_method",
        72 => "accessor",
        73 => "delegate",
        74 => "method_alias",
        75 => "singleton_class",
        76 => "singleton_method",
        77 => "static_data_member",
        78 => "static_event",
        79 => "static_field",
        80 => "static_method",
        81 => "static_property",
        82 => "static_variable",
        84 => "extension",
        85 => "mixin",
        86 => "concept",
        else => "unknown",
    };
}

// ── Decode functions ────────────────────────────────────────────────────

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Index {
    var dec = Decoder.init(data);

    var metadata: Metadata = .{
        .version = 0,
        .tool_info = .{ .name = "", .version = "" },
        .project_root = "",
        .text_document_encoding = 0,
    };
    var documents: std.ArrayListUnmanaged(Document) = .empty;
    defer documents.deinit(allocator);
    var external_symbols: std.ArrayListUnmanaged(SymbolInformation) = .empty;
    defer external_symbols.deinit(allocator);

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => { // metadata
                const sub_data = try dec.readLengthDelimited();
                metadata = try decodeMetadata(sub_data);
            },
            2 => { // documents
                const sub_data = try dec.readLengthDelimited();
                try documents.append(allocator, try decodeDocument(allocator, sub_data));
            },
            3 => { // external_symbols
                const sub_data = try dec.readLengthDelimited();
                try external_symbols.append(allocator, try decodeSymbolInformation(allocator, sub_data));
            },
            else => try dec.skipField(field.wire_type),
        }
    }

    return .{
        .metadata = metadata,
        .documents = try documents.toOwnedSlice(allocator),
        .external_symbols = try external_symbols.toOwnedSlice(allocator),
    };
}

fn decodeMetadata(data: []const u8) !Metadata {
    var dec = Decoder.init(data);
    var result: Metadata = .{
        .version = 0,
        .tool_info = .{ .name = "", .version = "" },
        .project_root = "",
        .text_document_encoding = 0,
    };

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => result.version = @intCast(try dec.readVarint()),
            2 => {
                const sub = try dec.readLengthDelimited();
                result.tool_info = try decodeToolInfo(sub);
            },
            3 => result.project_root = try dec.readString(),
            4 => result.text_document_encoding = @intCast(try dec.readVarint()),
            else => try dec.skipField(field.wire_type),
        }
    }
    return result;
}

fn decodeToolInfo(data: []const u8) !ToolInfo {
    var dec = Decoder.init(data);
    var result: ToolInfo = .{ .name = "", .version = "" };

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => result.name = try dec.readString(),
            2 => result.version = try dec.readString(),
            else => try dec.skipField(field.wire_type),
        }
    }
    return result;
}

fn decodeDocument(allocator: std.mem.Allocator, data: []const u8) !Document {
    var dec = Decoder.init(data);
    var result: Document = .{
        .language = "",
        .relative_path = "",
        .occurrences = &.{},
        .symbols = &.{},
    };

    var occurrences: std.ArrayListUnmanaged(Occurrence) = .empty;
    defer occurrences.deinit(allocator);
    var symbols: std.ArrayListUnmanaged(SymbolInformation) = .empty;
    defer symbols.deinit(allocator);

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => result.relative_path = try dec.readString(),
            2 => {
                const sub = try dec.readLengthDelimited();
                try occurrences.append(allocator, try decodeOccurrence(allocator, sub));
            },
            3 => {
                const sub = try dec.readLengthDelimited();
                try symbols.append(allocator, try decodeSymbolInformation(allocator, sub));
            },
            4 => result.language = try dec.readString(),
            else => try dec.skipField(field.wire_type),
        }
    }

    result.occurrences = try occurrences.toOwnedSlice(allocator);
    result.symbols = try symbols.toOwnedSlice(allocator);
    return result;
}

fn decodeOccurrence(allocator: std.mem.Allocator, data: []const u8) !Occurrence {
    var dec = Decoder.init(data);
    var result: Occurrence = .{
        .range = .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 0 },
        .symbol = "",
        .symbol_roles = 0,
        .syntax_kind = 0,
    };

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => { // range - packed int32
                const range_vals = try dec.readPackedInt32(allocator);
                defer allocator.free(range_vals);
                if (range_vals.len == 3) {
                    result.range = .{
                        .start_line = range_vals[0],
                        .start_char = range_vals[1],
                        .end_line = range_vals[0], // same as start
                        .end_char = range_vals[2],
                    };
                } else if (range_vals.len >= 4) {
                    result.range = .{
                        .start_line = range_vals[0],
                        .start_char = range_vals[1],
                        .end_line = range_vals[2],
                        .end_char = range_vals[3],
                    };
                }
            },
            2 => result.symbol = try dec.readString(),
            3 => result.symbol_roles = @intCast(try dec.readVarint()),
            5 => result.syntax_kind = @intCast(try dec.readVarint()),
            7 => { // enclosing_range - packed int32 (same encoding as range)
                const range_vals = try dec.readPackedInt32(allocator);
                defer allocator.free(range_vals);
                if (range_vals.len == 3) {
                    result.enclosing_range = .{
                        .start_line = range_vals[0],
                        .start_char = range_vals[1],
                        .end_line = range_vals[0],
                        .end_char = range_vals[2],
                    };
                } else if (range_vals.len >= 4) {
                    result.enclosing_range = .{
                        .start_line = range_vals[0],
                        .start_char = range_vals[1],
                        .end_line = range_vals[2],
                        .end_char = range_vals[3],
                    };
                }
            },
            else => try dec.skipField(field.wire_type),
        }
    }
    return result;
}

fn decodeSymbolInformation(allocator: std.mem.Allocator, data: []const u8) !SymbolInformation {
    var dec = Decoder.init(data);
    var result: SymbolInformation = .{
        .symbol = "",
        .documentation = &.{},
        .relationships = &.{},
        .kind = 0,
        .display_name = "",
        .enclosing_symbol = "",
    };

    var docs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer docs.deinit(allocator);
    var rels: std.ArrayListUnmanaged(Relationship) = .empty;
    defer rels.deinit(allocator);

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => result.symbol = try dec.readString(),
            3 => try docs.append(allocator, try dec.readString()),
            4 => {
                const sub = try dec.readLengthDelimited();
                try rels.append(allocator, try decodeRelationship(sub));
            },
            5 => result.kind = @intCast(try dec.readVarint()),
            6 => result.display_name = try dec.readString(),
            8 => result.enclosing_symbol = try dec.readString(),
            else => try dec.skipField(field.wire_type),
        }
    }

    result.documentation = try docs.toOwnedSlice(allocator);
    result.relationships = try rels.toOwnedSlice(allocator);
    return result;
}

fn decodeRelationship(data: []const u8) !Relationship {
    var dec = Decoder.init(data);
    var result: Relationship = .{
        .symbol = "",
        .is_reference = false,
        .is_implementation = false,
        .is_type_definition = false,
        .is_definition = false,
    };

    while (dec.hasMore()) {
        const field = try dec.readField();
        switch (field.number) {
            1 => result.symbol = try dec.readString(),
            2 => result.is_reference = (try dec.readVarint()) != 0,
            3 => result.is_implementation = (try dec.readVarint()) != 0,
            4 => result.is_type_definition = (try dec.readVarint()) != 0,
            5 => result.is_definition = (try dec.readVarint()) != 0,
            else => try dec.skipField(field.wire_type),
        }
    }
    return result;
}

/// Free allocated memory for a single document's internals.
pub fn freeDocument(allocator: std.mem.Allocator, doc: *Document) void {
    for (doc.symbols) |*sym| {
        allocator.free(sym.documentation);
        allocator.free(sym.relationships);
    }
    allocator.free(doc.occurrences);
    allocator.free(doc.symbols);
}

/// Free all allocated memory from a decoded Index.
pub fn freeIndex(allocator: std.mem.Allocator, index: *Index) void {
    for (index.documents) |*doc| {
        freeDocument(allocator, doc);
    }
    for (index.external_symbols) |*sym| {
        allocator.free(sym.documentation);
        allocator.free(sym.relationships);
    }
    allocator.free(index.documents);
    allocator.free(index.external_symbols);
}

// ── Symbol name extraction ──────────────────────────────────────────────

/// Extract the short name from a fully qualified SCIP symbol string.
/// For "scip-go gomod github.com/foo/bar v1.0.0 pkg/Server#Handle().",
/// returns "Handle".
pub fn extractSymbolName(symbol: []const u8) []const u8 {
    if (symbol.len == 0) return symbol;

    // Local symbols: "local N"
    if (std.mem.startsWith(u8, symbol, "local ")) {
        return symbol;
    }

    var end = symbol.len;

    // Strip trailing descriptor suffix
    const last = symbol[end - 1];
    if (last == '/' or last == '#' or last == ':' or last == '!') {
        // Simple suffix: namespace, type, meta, macro
        end -= 1;
    } else if (last == '.') {
        end -= 1;
        // Check if this is a method descriptor: name(disambiguator).
        if (end > 0 and symbol[end - 1] == ')') {
            end -= 1; // skip ')'
            // Find matching '('
            while (end > 0 and symbol[end - 1] != '(') {
                end -= 1;
            }
            if (end > 0) {
                end -= 1; // skip '('
            }
        }
        // Otherwise it's a term descriptor, name is right before '.'
    } else {
        return symbol;
    }

    // Scan backward from end to find the start of the name
    var start = end;
    while (start > 0) {
        const c = symbol[start - 1];
        if (c == '/' or c == '#' or c == '.' or c == ':' or c == '!' or c == ' ' or c == ')' or c == ']') {
            break;
        }
        start -= 1;
    }

    if (start < end) {
        return symbol[start..end];
    }
    return symbol;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "decode minimal Index" {
    const allocator = std.testing.allocator;

    // Build a minimal Index with just metadata
    // Metadata message: field 3 (project_root) = "file:///test"
    // project_root string "file:///test" = 12 bytes
    // field 3 LEN: tag = (3<<3)|2 = 0x1A, len = 12
    const project_root = "file:///test";
    const metadata_inner = [_]u8{0x1A} ++ [_]u8{project_root.len} ++ project_root.*;
    // Index field 1 (metadata) LEN:
    const tag_meta: u8 = (1 << 3) | 2; // 0x0A
    const index_data = [_]u8{tag_meta} ++ [_]u8{metadata_inner.len} ++ metadata_inner;

    var index = try decode(allocator, &index_data);
    defer freeIndex(allocator, &index);

    try std.testing.expectEqualStrings("file:///test", index.metadata.project_root);
    try std.testing.expectEqual(@as(usize, 0), index.documents.len);
    try std.testing.expectEqual(@as(usize, 0), index.external_symbols.len);
}

test "decode Document with occurrence" {
    const allocator = std.testing.allocator;

    // Build an Occurrence: range=[10, 5, 15] (3-element, single line)
    // field 1 (range) packed int32: tag = (1<<3)|2 = 0x0A
    // packed values: 10, 5, 15 => 0x0A, 0x05, 0x0F (3 bytes)
    // field 2 (symbol) string "pkg/Foo#bar.": tag = (2<<3)|2 = 0x12
    const symbol = "pkg/Foo#bar.";
    // field 3 (symbol_roles) varint 1 (Definition): tag = (3<<3)|0 = 0x18
    const occ_data = [_]u8{
        0x0A, 0x03, 0x0A, 0x05, 0x0F, // range packed [10, 5, 15]
        0x12, symbol.len,
    } ++ symbol.* ++ [_]u8{
        0x18, 0x01, // symbol_roles = 1
    };

    // Build Document: field 1 (relative_path) = "src/foo.go"
    const path = "src/foo.go";
    // field 2 (occurrences) LEN
    const doc_data = [_]u8{
        0x0A, path.len,
    } ++ path.* ++ [_]u8{
        0x12, occ_data.len,
    } ++ occ_data;

    // Build Index: field 2 (documents) LEN
    const index_data = [_]u8{
        0x12, doc_data.len,
    } ++ doc_data;

    var index = try decode(allocator, &index_data);
    defer freeIndex(allocator, &index);

    try std.testing.expectEqual(@as(usize, 1), index.documents.len);
    const doc = index.documents[0];
    try std.testing.expectEqualStrings("src/foo.go", doc.relative_path);
    try std.testing.expectEqual(@as(usize, 1), doc.occurrences.len);
    const occ = doc.occurrences[0];
    try std.testing.expectEqual(@as(i32, 10), occ.range.start_line);
    try std.testing.expectEqual(@as(i32, 5), occ.range.start_char);
    try std.testing.expectEqual(@as(i32, 10), occ.range.end_line); // single-line
    try std.testing.expectEqual(@as(i32, 15), occ.range.end_char);
    try std.testing.expectEqualStrings("pkg/Foo#bar.", occ.symbol);
    try std.testing.expect(SymbolRole.isDefinition(occ.symbol_roles));
}

test "decode SymbolInformation with relationships" {
    const allocator = std.testing.allocator;

    // Relationship: symbol="Animal#sound().", is_reference=true, is_implementation=true
    const rel_sym = "Animal#sound().";
    const rel_data = [_]u8{
        0x0A, rel_sym.len, // field 1 symbol
    } ++ rel_sym.* ++ [_]u8{
        0x10, 0x01, // field 2 is_reference = true
        0x18, 0x01, // field 3 is_implementation = true
    };

    // SymbolInformation: symbol="Dog#sound().", kind=26 (method), display_name="sound"
    const sym_str = "Dog#sound().";
    const display = "sound";
    const si_data = [_]u8{
        0x0A, sym_str.len, // field 1 symbol
    } ++ sym_str.* ++ [_]u8{
        0x22, rel_data.len, // field 4 relationship
    } ++ rel_data ++ [_]u8{
        0x28, 26, // field 5 kind = 26 (method)
        0x32, display.len, // field 6 display_name
    } ++ display.*;

    // Decode as part of a Document
    const path = "dog.go";
    const doc_data = [_]u8{
        0x0A, path.len,
    } ++ path.* ++ [_]u8{
        0x1A, si_data.len, // field 3 symbols
    } ++ si_data;

    const index_data = [_]u8{
        0x12, doc_data.len,
    } ++ doc_data;

    var index = try decode(allocator, &index_data);
    defer freeIndex(allocator, &index);

    try std.testing.expectEqual(@as(usize, 1), index.documents.len);
    const doc = index.documents[0];
    try std.testing.expectEqual(@as(usize, 1), doc.symbols.len);
    const sym = doc.symbols[0];
    try std.testing.expectEqualStrings("Dog#sound().", sym.symbol);
    try std.testing.expectEqual(@as(i32, 26), sym.kind);
    try std.testing.expectEqualStrings("sound", sym.display_name);
    try std.testing.expectEqual(@as(usize, 1), sym.relationships.len);
    try std.testing.expectEqualStrings("Animal#sound().", sym.relationships[0].symbol);
    try std.testing.expect(sym.relationships[0].is_reference);
    try std.testing.expect(sym.relationships[0].is_implementation);
}

test "extractSymbolName method" {
    const name = extractSymbolName("scip-go gomod github.com/foo/bar v1.0.0 pkg/Server#Handle().");
    try std.testing.expectEqualStrings("Handle", name);
}

test "extractSymbolName term" {
    const name = extractSymbolName("scip-go gomod github.com/foo v1 pkg/MyVar.");
    try std.testing.expectEqualStrings("MyVar", name);
}

test "extractSymbolName type" {
    const name = extractSymbolName("scip-go gomod github.com/foo v1 pkg/MyStruct#");
    try std.testing.expectEqualStrings("MyStruct", name);
}

test "extractSymbolName namespace" {
    const name = extractSymbolName("scip-go gomod github.com/foo v1 pkg/");
    try std.testing.expectEqualStrings("pkg", name);
}

test "extractSymbolName local" {
    const name = extractSymbolName("local 42");
    try std.testing.expectEqualStrings("local 42", name);
}

test "Range 4-element (multi-line)" {
    const allocator = std.testing.allocator;

    // Occurrence with 4-element range: [5, 10, 7, 25]
    const occ_data = [_]u8{
        0x0A, 0x04, 0x05, 0x0A, 0x07, 0x19, // range packed [5, 10, 7, 25]
    };

    const path = "test.go";
    const doc_data = [_]u8{
        0x0A, path.len,
    } ++ path.* ++ [_]u8{
        0x12, occ_data.len,
    } ++ occ_data;

    const index_data = [_]u8{
        0x12, doc_data.len,
    } ++ doc_data;

    var index = try decode(allocator, &index_data);
    defer freeIndex(allocator, &index);

    const occ = index.documents[0].occurrences[0];
    try std.testing.expectEqual(@as(i32, 5), occ.range.start_line);
    try std.testing.expectEqual(@as(i32, 10), occ.range.start_char);
    try std.testing.expectEqual(@as(i32, 7), occ.range.end_line);
    try std.testing.expectEqual(@as(i32, 25), occ.range.end_char);
}

test "kindName known kinds" {
    try std.testing.expectEqualStrings("function", kindName(17));
    try std.testing.expectEqualStrings("struct", kindName(49));
    try std.testing.expectEqualStrings("method", kindName(26));
    try std.testing.expectEqualStrings("class", kindName(7));
    try std.testing.expectEqualStrings("unknown", kindName(999));
}

test "SymbolRole.describe" {
    try std.testing.expectEqualStrings("definition", SymbolRole.describe(0x1));
    try std.testing.expectEqualStrings("import", SymbolRole.describe(0x2));
    try std.testing.expectEqualStrings("write", SymbolRole.describe(0x4));
    try std.testing.expectEqualStrings("read", SymbolRole.describe(0x8));
    try std.testing.expectEqualStrings("reference", SymbolRole.describe(0));
}
