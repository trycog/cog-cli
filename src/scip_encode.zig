const std = @import("std");
const scip = @import("scip.zig");
const protobuf = @import("protobuf.zig");
const Encoder = protobuf.Encoder;

/// Encode a SCIP Index to protobuf bytes. Caller owns the returned slice.
pub fn encodeIndex(allocator: std.mem.Allocator, index: scip.Index) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: metadata
    const meta_bytes = try encodeMetadata(allocator, index.metadata);
    defer allocator.free(meta_bytes);
    if (meta_bytes.len > 0) {
        try enc.writeLengthDelimited(1, meta_bytes);
    }

    // field 2: documents (repeated)
    for (index.documents) |doc| {
        const doc_bytes = try encodeDocument(allocator, doc);
        defer allocator.free(doc_bytes);
        try enc.writeLengthDelimited(2, doc_bytes);
    }

    // field 3: external_symbols (repeated)
    for (index.external_symbols) |sym| {
        const sym_bytes = try encodeSymbolInformation(allocator, sym);
        defer allocator.free(sym_bytes);
        try enc.writeLengthDelimited(3, sym_bytes);
    }

    return enc.toOwnedSlice();
}

/// Encode Metadata message.
pub fn encodeMetadata(allocator: std.mem.Allocator, metadata: scip.Metadata) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: version (int32)
    try enc.writeVarintField(1, @intCast(metadata.version));

    // field 2: tool_info
    const ti_bytes = try encodeToolInfo(allocator, metadata.tool_info);
    defer allocator.free(ti_bytes);
    if (ti_bytes.len > 0) {
        try enc.writeLengthDelimited(2, ti_bytes);
    }

    // field 3: project_root (string)
    try enc.writeString(3, metadata.project_root);

    // field 4: text_document_encoding (int32)
    try enc.writeVarintField(4, @intCast(metadata.text_document_encoding));

    return enc.toOwnedSlice();
}

/// Encode ToolInfo message.
pub fn encodeToolInfo(allocator: std.mem.Allocator, info: scip.ToolInfo) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: name
    try enc.writeString(1, info.name);
    // field 2: version
    try enc.writeString(2, info.version);

    return enc.toOwnedSlice();
}

/// Encode a Document message.
pub fn encodeDocument(allocator: std.mem.Allocator, doc: scip.Document) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: relative_path
    try enc.writeString(1, doc.relative_path);

    // field 2: occurrences (repeated)
    for (doc.occurrences) |occ| {
        const occ_bytes = try encodeOccurrence(allocator, occ);
        defer allocator.free(occ_bytes);
        try enc.writeLengthDelimited(2, occ_bytes);
    }

    // field 3: symbols (repeated)
    for (doc.symbols) |sym| {
        const sym_bytes = try encodeSymbolInformation(allocator, sym);
        defer allocator.free(sym_bytes);
        try enc.writeLengthDelimited(3, sym_bytes);
    }

    // field 4: language
    try enc.writeString(4, doc.language);

    return enc.toOwnedSlice();
}

/// Encode an Occurrence message.
pub fn encodeOccurrence(allocator: std.mem.Allocator, occ: scip.Occurrence) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: range (packed int32)
    if (occ.range.start_line == occ.range.end_line) {
        // 3-element range: [start_line, start_char, end_char]
        try enc.writePackedInt32(1, &.{ occ.range.start_line, occ.range.start_char, occ.range.end_char });
    } else {
        // 4-element range: [start_line, start_char, end_line, end_char]
        try enc.writePackedInt32(1, &.{ occ.range.start_line, occ.range.start_char, occ.range.end_line, occ.range.end_char });
    }

    // field 2: symbol
    try enc.writeString(2, occ.symbol);

    // field 3: symbol_roles
    try enc.writeVarintField(3, @intCast(occ.symbol_roles));

    // field 5: syntax_kind
    try enc.writeVarintField(5, @intCast(occ.syntax_kind));

    // field 7: enclosing_range (packed int32, same encoding as range)
    if (occ.enclosing_range) |er| {
        if (er.start_line == er.end_line) {
            try enc.writePackedInt32(7, &.{ er.start_line, er.start_char, er.end_char });
        } else {
            try enc.writePackedInt32(7, &.{ er.start_line, er.start_char, er.end_line, er.end_char });
        }
    }

    return enc.toOwnedSlice();
}

/// Encode a SymbolInformation message.
pub fn encodeSymbolInformation(allocator: std.mem.Allocator, sym: scip.SymbolInformation) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: symbol
    try enc.writeString(1, sym.symbol);

    // field 3: documentation (repeated string)
    for (sym.documentation) |doc_str| {
        try enc.writeString(3, doc_str);
    }

    // field 4: relationships (repeated)
    for (sym.relationships) |rel| {
        const rel_bytes = try encodeRelationship(allocator, rel);
        defer allocator.free(rel_bytes);
        try enc.writeLengthDelimited(4, rel_bytes);
    }

    // field 5: kind
    try enc.writeVarintField(5, @intCast(sym.kind));

    // field 6: display_name
    try enc.writeString(6, sym.display_name);

    // field 8: enclosing_symbol
    try enc.writeString(8, sym.enclosing_symbol);

    return enc.toOwnedSlice();
}

/// Encode a Relationship message.
pub fn encodeRelationship(allocator: std.mem.Allocator, rel: scip.Relationship) ![]const u8 {
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    // field 1: symbol
    try enc.writeString(1, rel.symbol);
    // field 2: is_reference
    try enc.writeBool(2, rel.is_reference);
    // field 3: is_implementation
    try enc.writeBool(3, rel.is_implementation);
    // field 4: is_type_definition
    try enc.writeBool(4, rel.is_type_definition);
    // field 5: is_definition
    try enc.writeBool(5, rel.is_definition);

    return enc.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "round-trip empty Index" {
    const allocator = std.testing.allocator;

    var docs = [_]scip.Document{};
    var ext_syms = [_]scip.SymbolInformation{};

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "", .version = "" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &docs,
        .external_symbols = &ext_syms,
    };

    const encoded = try encodeIndex(allocator, index);
    defer allocator.free(encoded);

    var decoded = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.documents.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.external_symbols.len);
}

test "round-trip Index with metadata" {
    const allocator = std.testing.allocator;

    var docs = [_]scip.Document{};
    var ext_syms = [_]scip.SymbolInformation{};

    const index: scip.Index = .{
        .metadata = .{
            .version = 1,
            .tool_info = .{ .name = "scip-go", .version = "1.0" },
            .project_root = "file:///test",
            .text_document_encoding = 0,
        },
        .documents = &docs,
        .external_symbols = &ext_syms,
    };

    const encoded = try encodeIndex(allocator, index);
    defer allocator.free(encoded);

    var decoded = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &decoded);

    try std.testing.expectEqual(@as(i32, 1), decoded.metadata.version);
    try std.testing.expectEqualStrings("scip-go", decoded.metadata.tool_info.name);
    try std.testing.expectEqualStrings("1.0", decoded.metadata.tool_info.version);
    try std.testing.expectEqualStrings("file:///test", decoded.metadata.project_root);
}

test "round-trip Document with occurrence" {
    const allocator = std.testing.allocator;

    var occs = [_]scip.Occurrence{
        .{
            .range = .{ .start_line = 10, .start_char = 5, .end_line = 10, .end_char = 15 },
            .symbol = "pkg/Foo#bar.",
            .symbol_roles = scip.SymbolRole.Definition,
            .syntax_kind = 0,
        },
    };
    var syms = [_]scip.SymbolInformation{};
    var docs = [_]scip.Document{
        .{
            .language = "go",
            .relative_path = "src/foo.go",
            .occurrences = &occs,
            .symbols = &syms,
        },
    };
    var ext_syms = [_]scip.SymbolInformation{};

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "", .version = "" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &docs,
        .external_symbols = &ext_syms,
    };

    const encoded = try encodeIndex(allocator, index);
    defer allocator.free(encoded);

    var decoded = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.documents.len);
    const doc = decoded.documents[0];
    try std.testing.expectEqualStrings("src/foo.go", doc.relative_path);
    try std.testing.expectEqualStrings("go", doc.language);
    try std.testing.expectEqual(@as(usize, 1), doc.occurrences.len);

    const occ = doc.occurrences[0];
    try std.testing.expectEqual(@as(i32, 10), occ.range.start_line);
    try std.testing.expectEqual(@as(i32, 5), occ.range.start_char);
    try std.testing.expectEqual(@as(i32, 10), occ.range.end_line);
    try std.testing.expectEqual(@as(i32, 15), occ.range.end_char);
    try std.testing.expectEqualStrings("pkg/Foo#bar.", occ.symbol);
    try std.testing.expect(scip.SymbolRole.isDefinition(occ.symbol_roles));
}

test "round-trip multi-line occurrence range" {
    const allocator = std.testing.allocator;

    var occs = [_]scip.Occurrence{
        .{
            .range = .{ .start_line = 5, .start_char = 10, .end_line = 7, .end_char = 25 },
            .symbol = "pkg/Foo#",
            .symbol_roles = 0,
            .syntax_kind = 0,
        },
    };
    var syms = [_]scip.SymbolInformation{};
    var docs = [_]scip.Document{
        .{
            .language = "",
            .relative_path = "test.go",
            .occurrences = &occs,
            .symbols = &syms,
        },
    };
    var ext_syms = [_]scip.SymbolInformation{};

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "", .version = "" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &docs,
        .external_symbols = &ext_syms,
    };

    const encoded = try encodeIndex(allocator, index);
    defer allocator.free(encoded);

    var decoded = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &decoded);

    const occ = decoded.documents[0].occurrences[0];
    try std.testing.expectEqual(@as(i32, 5), occ.range.start_line);
    try std.testing.expectEqual(@as(i32, 10), occ.range.start_char);
    try std.testing.expectEqual(@as(i32, 7), occ.range.end_line);
    try std.testing.expectEqual(@as(i32, 25), occ.range.end_char);
}

test "round-trip SymbolInformation with relationships" {
    const allocator = std.testing.allocator;

    var rels = [_]scip.Relationship{
        .{
            .symbol = "Animal#sound().",
            .is_reference = true,
            .is_implementation = true,
            .is_type_definition = false,
            .is_definition = false,
        },
    };
    var occs = [_]scip.Occurrence{};
    var doc_syms = [_]scip.SymbolInformation{
        .{
            .symbol = "Dog#sound().",
            .documentation = &.{"Makes a sound"},
            .relationships = &rels,
            .kind = 26,
            .display_name = "sound",
            .enclosing_symbol = "Dog#",
        },
    };
    var docs = [_]scip.Document{
        .{
            .language = "go",
            .relative_path = "dog.go",
            .occurrences = &occs,
            .symbols = &doc_syms,
        },
    };
    var ext_syms = [_]scip.SymbolInformation{};

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "", .version = "" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &docs,
        .external_symbols = &ext_syms,
    };

    const encoded = try encodeIndex(allocator, index);
    defer allocator.free(encoded);

    var decoded = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.documents.len);
    const doc = decoded.documents[0];
    try std.testing.expectEqual(@as(usize, 1), doc.symbols.len);

    const sym = doc.symbols[0];
    try std.testing.expectEqualStrings("Dog#sound().", sym.symbol);
    try std.testing.expectEqual(@as(i32, 26), sym.kind);
    try std.testing.expectEqualStrings("sound", sym.display_name);
    try std.testing.expectEqualStrings("Dog#", sym.enclosing_symbol);
    try std.testing.expectEqual(@as(usize, 1), sym.documentation.len);
    try std.testing.expectEqualStrings("Makes a sound", sym.documentation[0]);

    try std.testing.expectEqual(@as(usize, 1), sym.relationships.len);
    const rel = sym.relationships[0];
    try std.testing.expectEqualStrings("Animal#sound().", rel.symbol);
    try std.testing.expect(rel.is_reference);
    try std.testing.expect(rel.is_implementation);
    try std.testing.expect(!rel.is_type_definition);
    try std.testing.expect(!rel.is_definition);
}

test "round-trip external symbols" {
    const allocator = std.testing.allocator;

    var docs = [_]scip.Document{};
    var rels = [_]scip.Relationship{};
    var ext_syms = [_]scip.SymbolInformation{
        .{
            .symbol = "ext/Package#Type#",
            .documentation = &.{},
            .relationships = &rels,
            .kind = 49,
            .display_name = "Type",
            .enclosing_symbol = "",
        },
    };

    const index: scip.Index = .{
        .metadata = .{
            .version = 0,
            .tool_info = .{ .name = "", .version = "" },
            .project_root = "",
            .text_document_encoding = 0,
        },
        .documents = &docs,
        .external_symbols = &ext_syms,
    };

    const encoded = try encodeIndex(allocator, index);
    defer allocator.free(encoded);

    var decoded = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.external_symbols.len);
    try std.testing.expectEqualStrings("ext/Package#Type#", decoded.external_symbols[0].symbol);
    try std.testing.expectEqual(@as(i32, 49), decoded.external_symbols[0].kind);
    try std.testing.expectEqualStrings("Type", decoded.external_symbols[0].display_name);
}
