const std = @import("std");

pub const GrammarSource = struct {
    name: []const u8,
    repo: []const u8,
    commit: []const u8,
    archive_sha256: []const u8,
    src_prefix: []const u8,
    has_scanner: bool,
};

pub const CompiledGrammar = struct {
    name: []const u8,
    has_scanner: bool,
};

pub const tree_sitter_source = GrammarSource{
    .name = "tree-sitter",
    .repo = "tree-sitter/tree-sitter",
    .commit = "726dcd1e872149d95de581589fc408fb8ea9cb0b", // v0.25.4
    .archive_sha256 = "65aad2f0c1cad144a973b46790901adcc78ee72d2f628cf79003680ab0f133b1",
    .src_prefix = "lib",
    .has_scanner = false,
};

pub const grammars = [_]GrammarSource{
    .{ .name = "c", .repo = "tree-sitter/tree-sitter-c", .commit = "7fa1be1b694b6e763686793d97da01f36a0e5c12", .archive_sha256 = "62e56fe3031e0b05831bbffd392b00c55c280e0ea953ead49a30254bf9fb9ce8", .src_prefix = "src", .has_scanner = false }, // v0.24.1
    .{ .name = "cpp", .repo = "tree-sitter/tree-sitter-cpp", .commit = "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02", .archive_sha256 = "ad4b9b56602e9b14082637988f0042521006819960ed8c308bc24ded9ceb9331", .src_prefix = "src", .has_scanner = true }, // v0.23.4
    .{ .name = "go", .repo = "tree-sitter/tree-sitter-go", .commit = "1547678a9da59885853f5f5cc8a99cc203fa2e2c", .archive_sha256 = "a71543d63f82b917457f47a3f6dbecd8087592fabc49a757da82c3e00c0e93de", .src_prefix = "src", .has_scanner = false }, // v0.25.0
    .{ .name = "json", .repo = "tree-sitter/tree-sitter-json", .commit = "ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24", .archive_sha256 = "9e4a7391cc3a9f4b87b382956dd01bc1f99fb1afcdc86b2c152c8a1bd14444d5", .src_prefix = "src", .has_scanner = false }, // v0.24.8
    .{ .name = "java", .repo = "tree-sitter/tree-sitter-java", .commit = "94703d5a6bed02b98e438d7cad1136c01a60ba2c", .archive_sha256 = "39dea56cc3bb5fb1658f79b195a92b6f08885886bca636adf2dc6243af641c47", .src_prefix = "src", .has_scanner = false }, // v0.23.5
    .{ .name = "javascript", .repo = "tree-sitter/tree-sitter-javascript", .commit = "44c892e0be055ac465d5eeddae6d3e194424e7de", .archive_sha256 = "a13fa28148e41bb939b2c2b8cd73c4b4295273b70cbac55a7a589020f52b9611", .src_prefix = "src", .has_scanner = true }, // v0.25.0
    .{ .name = "markdown", .repo = "tree-sitter-grammars/tree-sitter-markdown", .commit = "2dfd57f547f06ca5631a80f601e129d73fc8e9f0", .archive_sha256 = "74138adf4535291593560d401bf0a6f0b3cc8a0c43d0912f462e5590f7e8fbb9", .src_prefix = "tree-sitter-markdown/src", .has_scanner = true }, // v0.5.1
    .{ .name = "mdx", .repo = "srazzak/tree-sitter-mdx", .commit = "3aa29e8de1bf0213948a04fe953039b6ab73777b", .archive_sha256 = "699d141299773dcd45abfec00e7c2eba46e67c60e540b763e2c2a0f7d7f5104e", .src_prefix = "src", .has_scanner = true }, // main on 2026-08-13
    .{ .name = "python", .repo = "tree-sitter/tree-sitter-python", .commit = "293fdc02038ee2bf0e2e206711b69c90ac0d413f", .archive_sha256 = "b74d8ba6730535354175436208fe1452fd464f235263959ca40b8bf32cb23dc6", .src_prefix = "src", .has_scanner = true }, // v0.25.0
    .{ .name = "rst", .repo = "stsewd/tree-sitter-rst", .commit = "ab09cab886a947c62a8c6fa94d3ad375f3f6a73d", .archive_sha256 = "93b1cca532209a105da59e1d95f17a4ee4f0de8a9791778e758c9b3a090ad48d", .src_prefix = "src", .has_scanner = true }, // v0.2.0
    .{ .name = "rust", .repo = "tree-sitter/tree-sitter-rust", .commit = "18b0515fca567f5a10aee9978c6d2640e878671a", .archive_sha256 = "af3dc21a2985201f764eb94709f09277500fb732f1863f9bdd6371147ca7afe7", .src_prefix = "src", .has_scanner = true }, // v0.24.0
    .{ .name = "toml", .repo = "tree-sitter-grammars/tree-sitter-toml", .commit = "64b56832c2cffe41758f28e05c756a3a98d16f41", .archive_sha256 = "feeb2e1cf531588cdcfb9c57292620151a08597f18a98dad26cc17fd4b544dcb", .src_prefix = "src", .has_scanner = true }, // v0.7.0
    .{ .name = "typescript", .repo = "tree-sitter/tree-sitter-typescript", .commit = "f975a621f4e7f532fe322e13c4f79495e0a7b2e7", .archive_sha256 = "4de2e82e557810eecb93cb3b31fbb3bd28ba4c91ba9a6c6164bcaa074125b7b5", .src_prefix = "typescript/src", .has_scanner = true }, // v0.23.2
    .{ .name = "tsx", .repo = "tree-sitter/tree-sitter-typescript", .commit = "f975a621f4e7f532fe322e13c4f79495e0a7b2e7", .archive_sha256 = "4de2e82e557810eecb93cb3b31fbb3bd28ba4c91ba9a6c6164bcaa074125b7b5", .src_prefix = "tsx/src", .has_scanner = true }, // v0.23.2
    .{ .name = "yaml", .repo = "tree-sitter-grammars/tree-sitter-yaml", .commit = "7708026449bed86239b1cd5bce6e3c34dbca6415", .archive_sha256 = "6e8cb69a4f7a05478b1143d38bd10df2163170a6678df1848f3be89c8b7c5f3b", .src_prefix = "src", .has_scanner = true }, // v0.7.2
    .{ .name = "asciidoc", .repo = "cathaysia/tree-sitter-asciidoc", .commit = "2ce221b7cd33f4a0ebf84759c4dc821a2bdba0dd", .archive_sha256 = "ba7f67188e2db9ba60eacbb35ca0bc9243b65bb1a8bd8ee9c6b3cac1a195721a", .src_prefix = "tree-sitter-asciidoc/src", .has_scanner = true }, // v0.6.0
    .{ .name = "bash", .repo = "tree-sitter/tree-sitter-bash", .commit = "a06c2e4415e9bc0346c6b86d401879ffb44058f7", .archive_sha256 = "879e8951ea2cc82455407e3eda0293319657ec53e83191e0fb5a67430d10d804", .src_prefix = "src", .has_scanner = true }, // v0.25.1
};

pub const compiled_grammars = [_]CompiledGrammar{
    .{ .name = "c", .has_scanner = false },
    .{ .name = "cpp", .has_scanner = true },
    .{ .name = "go", .has_scanner = false },
    .{ .name = "json", .has_scanner = false },
    .{ .name = "java", .has_scanner = false },
    .{ .name = "javascript", .has_scanner = true },
    .{ .name = "markdown", .has_scanner = true },
    .{ .name = "mdx", .has_scanner = true },
    .{ .name = "python", .has_scanner = true },
    .{ .name = "rst", .has_scanner = true },
    .{ .name = "rust", .has_scanner = true },
    .{ .name = "toml", .has_scanner = true },
    .{ .name = "typescript", .has_scanner = true },
    .{ .name = "tsx", .has_scanner = true },
    .{ .name = "yaml", .has_scanner = true },
    .{ .name = "asciidoc", .has_scanner = true },
    .{ .name = "bash", .has_scanner = true },
};

test "external source table covers every compiled grammar with immutable verified pins" {
    try expectImmutableSource(tree_sitter_source);
    try std.testing.expectEqual(compiled_grammars.len, grammars.len);
    for (grammars, compiled_grammars) |source, compiled| {
        try std.testing.expectEqualStrings(compiled.name, source.name);
        try std.testing.expectEqual(compiled.has_scanner, source.has_scanner);
        try expectImmutableSource(source);
    }

    const typescript = grammars[12];
    const tsx = grammars[13];
    try std.testing.expectEqualStrings(typescript.repo, tsx.repo);
    try std.testing.expectEqualStrings(typescript.commit, tsx.commit);
    try std.testing.expectEqualStrings(typescript.archive_sha256, tsx.archive_sha256);
}

fn expectImmutableSource(source: GrammarSource) !void {
    try std.testing.expectEqual(@as(usize, 40), source.commit.len);
    try std.testing.expectEqual(@as(usize, 64), source.archive_sha256.len);
    for (source.commit) |char| try std.testing.expect(std.ascii.isHex(char) and !std.ascii.isUpper(char));
    for (source.archive_sha256) |char| try std.testing.expect(std.ascii.isHex(char) and !std.ascii.isUpper(char));
}
