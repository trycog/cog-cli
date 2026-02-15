const std = @import("std");

const tree_sitter_version = "v0.25.4";

const GrammarSource = struct {
    name: []const u8,
    repo: []const u8,
    tag: []const u8,
    src_prefix: []const u8,
    has_scanner: bool,
};

const grammars = [_]GrammarSource{
    .{ .name = "c", .repo = "tree-sitter/tree-sitter-c", .tag = "v0.24.1", .src_prefix = "src", .has_scanner = false },
    .{ .name = "cpp", .repo = "tree-sitter/tree-sitter-cpp", .tag = "v0.23.4", .src_prefix = "src", .has_scanner = true },
    .{ .name = "go", .repo = "tree-sitter/tree-sitter-go", .tag = "v0.25.0", .src_prefix = "src", .has_scanner = false },
    .{ .name = "java", .repo = "tree-sitter/tree-sitter-java", .tag = "v0.23.5", .src_prefix = "src", .has_scanner = false },
    .{ .name = "javascript", .repo = "tree-sitter/tree-sitter-javascript", .tag = "v0.25.0", .src_prefix = "src", .has_scanner = true },
    .{ .name = "python", .repo = "tree-sitter/tree-sitter-python", .tag = "v0.25.0", .src_prefix = "src", .has_scanner = true },
    .{ .name = "rust", .repo = "tree-sitter/tree-sitter-rust", .tag = "v0.24.0", .src_prefix = "src", .has_scanner = true },
    .{ .name = "typescript", .repo = "tree-sitter/tree-sitter-typescript", .tag = "v0.23.2", .src_prefix = "typescript/src", .has_scanner = true },
    .{ .name = "tsx", .repo = "tree-sitter/tree-sitter-typescript", .tag = "v0.23.2", .src_prefix = "tsx/src", .has_scanner = true },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Check that grammars are downloaded (runs at execution time, not construction)
    const check_grammars = b.addSystemCommand(&.{
        "sh", "-c",
        \\test -f grammars/tree-sitter/src/lib.c || {
        \\  printf '\nerror: Grammars not found. Run setup first:\n\n    zig build setup\n\n' >&2
        \\  exit 1
        \\}
    });

    // Root module (library)
    const mod = b.addModule("cog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    addTreeSitter(b, mod);

    // Executable
    const exe = b.addExecutable(.{
        .name = "cog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cog", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Benchmark
    const bench_exe = b.addExecutable(.{
        .name = "bench-query",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_query.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep()); // ensure cog binary is built
    const bench_step = b.step("bench", "Run query benchmark");
    bench_step.dependOn(&bench_run.step);
    if (b.args) |args| bench_run.addArgs(args);

    // Grammar check: compilation depends on it, setup does not
    exe.step.dependOn(&check_grammars.step);
    mod_tests.step.dependOn(&check_grammars.step);
    exe_tests.step.dependOn(&check_grammars.step);

    // Setup step (download grammars)
    addSetupStep(b);

    // Release step
    const release_step = b.step("release", "Build release tarballs");
    addRelease(b, release_step, .aarch64, .macos, "darwin-arm64");
    addRelease(b, release_step, .x86_64, .macos, "darwin-x86_64");
    addRelease(b, release_step, .aarch64, .linux, "linux-arm64");
    addRelease(b, release_step, .x86_64, .linux, "linux-x86_64");
}

/// Add tree-sitter core and all grammar C source files to a module.
fn addTreeSitter(b: *std.Build, mod: *std.Build.Module) void {
    const ts_include = b.path("grammars/tree-sitter/include");
    const ts_src = b.path("grammars/tree-sitter/src");

    // Include paths
    mod.addIncludePath(ts_include);
    mod.addIncludePath(ts_src);
    mod.addIncludePath(b.path("grammars/go"));
    mod.addIncludePath(b.path("grammars/java"));
    mod.addIncludePath(b.path("grammars/c"));
    mod.addIncludePath(b.path("grammars/typescript"));
    mod.addIncludePath(b.path("grammars/tsx"));
    mod.addIncludePath(b.path("grammars/javascript"));
    mod.addIncludePath(b.path("grammars/python"));
    mod.addIncludePath(b.path("grammars/rust"));
    mod.addIncludePath(b.path("grammars/cpp"));

    const c_flags = &[_][]const u8{ "-std=c11", "-fno-exceptions" };

    // Tree-sitter core (unity build via lib.c)
    mod.addCSourceFile(.{
        .file = b.path("grammars/tree-sitter/src/lib.c"),
        .flags = c_flags,
    });

    // Grammar parsers (parser-only: Go, Java, C)
    mod.addCSourceFile(.{ .file = b.path("grammars/go/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/java/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/c/parser.c"), .flags = c_flags });

    // Grammar parsers + scanners: TypeScript, TSX, JavaScript, Python, Rust, C++
    mod.addCSourceFile(.{ .file = b.path("grammars/typescript/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/typescript/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/tsx/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/tsx/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/javascript/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/javascript/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/python/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/python/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/rust/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/rust/scanner.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/cpp/parser.c"), .flags = c_flags });
    mod.addCSourceFile(.{ .file = b.path("grammars/cpp/scanner.c"), .flags = c_flags });
}

fn addRelease(
    b: *std.Build,
    release_step: *std.Build.Step,
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    name: []const u8,
) void {
    const release_target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = os_tag,
    });

    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = release_target,
        .link_libc = true,
    });
    addTreeSitter(b, release_mod);

    const release_exe = b.addExecutable(.{
        .name = "cog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "cog", .module = release_mod },
            },
        }),
    });

    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const output = tar.addOutputFileArg(b.fmt("cog-{s}.tar.gz", .{name}));
    tar.addArgs(&.{"-C"});
    tar.addDirectoryArg(release_exe.getEmittedBin().dirname());
    tar.addArg("cog");

    const install_tar = b.addInstallFileWithDir(
        output,
        .{ .custom = "release" },
        b.fmt("cog-{s}.tar.gz", .{name}),
    );
    release_step.dependOn(&install_tar.step);
}

fn addSetupStep(b: *std.Build) void {
    const setup_step = b.step("setup", "Download tree-sitter grammars");
    setup_step.dependOn(addDownloadCore(b));

    // Track whether we've already added the typescript repo download
    var ts_step: ?*std.Build.Step = null;

    for (grammars) |g| {
        if (std.mem.eql(u8, g.name, "typescript") or std.mem.eql(u8, g.name, "tsx")) {
            if (ts_step == null) {
                ts_step = addDownloadTypescript(b);
            }
            setup_step.dependOn(ts_step.?);
        } else {
            setup_step.dependOn(addDownloadGrammar(b, g));
        }
    }
}

fn addDownloadCore(b: *std.Build) *std.Build.Step {
    const script = b.fmt(
        \\set -e
        \\mkdir -p grammars/tree-sitter/src grammars/tree-sitter/include
        \\TMPDIR=$(mktemp -d)
        \\curl -sL "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/{s}.tar.gz" | tar xz -C "$TMPDIR"
        \\EXTRACTED="$TMPDIR/tree-sitter-{s}"
        \\cp -R "$EXTRACTED/lib/src/"* grammars/tree-sitter/src/
        \\cp -R "$EXTRACTED/lib/include/"* grammars/tree-sitter/include/
        \\rm -rf "$TMPDIR"
        \\echo "Downloaded tree-sitter {s}"
    , .{
        tree_sitter_version,
        tree_sitter_version[1..], // strip leading 'v' for directory name
        tree_sitter_version,
    });
    const cmd = b.addSystemCommand(&.{ "sh", "-c", script });
    return &cmd.step;
}

fn addDownloadGrammar(b: *std.Build, g: GrammarSource) *std.Build.Step {
    const scanner_cp = if (g.has_scanner)
        b.fmt("cp \"$EXTRACTED/{s}/scanner.c\" \"grammars/{s}/scanner.c\"\n", .{ g.src_prefix, g.name })
    else
        "";

    const script = b.fmt(
        \\set -e
        \\mkdir -p "grammars/{s}/tree_sitter"
        \\TMPDIR=$(mktemp -d)
        \\curl -sL "https://github.com/{s}/archive/refs/tags/{s}.tar.gz" | tar xz -C "$TMPDIR"
        \\REPO_NAME=$(echo "{s}" | sed 's|.*/||')
        \\TAG_STRIPPED=$(echo "{s}" | sed 's/^v//')
        \\EXTRACTED="$TMPDIR/$REPO_NAME-$TAG_STRIPPED"
        \\cp "$EXTRACTED/{s}/parser.c" "grammars/{s}/parser.c"
        \\{s}cp "$EXTRACTED/{s}/tree_sitter/"*.h "grammars/{s}/tree_sitter/"
        \\if [ -f "$EXTRACTED/tags.scm" ]; then cp "$EXTRACTED/tags.scm" "grammars/{s}/tags.scm"; fi
        \\if [ -f "$EXTRACTED/{s}/tags.scm" ]; then cp "$EXTRACTED/{s}/tags.scm" "grammars/{s}/tags.scm"; fi
        \\rm -rf "$TMPDIR"
        \\echo "Downloaded {s} grammar ({s})"
    , .{
        g.name,        // mkdir target
        g.repo,        // curl URL repo
        g.tag,         // curl URL tag
        g.repo,        // repo name extraction
        g.tag,         // tag stripping
        g.src_prefix,  // parser.c source
        g.name,        // parser.c dest
        scanner_cp,    // optional scanner copy
        g.src_prefix,  // tree_sitter headers source
        g.name,        // tree_sitter headers dest
        g.name,        // tags.scm root check dest
        g.src_prefix,  // tags.scm prefix -f check
        g.src_prefix,  // tags.scm prefix cp source
        g.name,        // tags.scm prefix check dest
        g.name,        // echo name
        g.tag,         // echo tag
    });
    const cmd = b.addSystemCommand(&.{ "sh", "-c", script });
    return &cmd.step;
}

fn addDownloadTypescript(b: *std.Build) *std.Build.Step {
    const tag = "v0.23.2";
    const script = b.fmt(
        \\set -e
        \\mkdir -p grammars/typescript/tree_sitter grammars/tsx/tree_sitter grammars/common
        \\TMPDIR=$(mktemp -d)
        \\curl -sL "https://github.com/tree-sitter/tree-sitter-typescript/archive/refs/tags/{s}.tar.gz" | tar xz -C "$TMPDIR"
        \\EXTRACTED="$TMPDIR/tree-sitter-typescript-{s}"
        \\cp "$EXTRACTED/typescript/src/parser.c" grammars/typescript/parser.c
        \\cp "$EXTRACTED/typescript/src/scanner.c" grammars/typescript/scanner.c
        \\cp "$EXTRACTED/typescript/src/tree_sitter/"*.h grammars/typescript/tree_sitter/
        \\if [ -f "$EXTRACTED/typescript/tags.scm" ]; then cp "$EXTRACTED/typescript/tags.scm" grammars/typescript/tags.scm; fi
        \\cp "$EXTRACTED/tsx/src/parser.c" grammars/tsx/parser.c
        \\cp "$EXTRACTED/tsx/src/scanner.c" grammars/tsx/scanner.c
        \\cp "$EXTRACTED/tsx/src/tree_sitter/"*.h grammars/tsx/tree_sitter/
        \\if [ -f "$EXTRACTED/tsx/tags.scm" ]; then cp "$EXTRACTED/tsx/tags.scm" grammars/tsx/tags.scm; fi
        \\cp "$EXTRACTED/common/scanner.h" grammars/common/scanner.h
        \\rm -rf "$TMPDIR"
        \\echo "Downloaded typescript/tsx grammars ({s})"
    , .{ tag, tag[1..], tag });
    const cmd = b.addSystemCommand(&.{ "sh", "-c", script });
    return &cmd.step;
}
