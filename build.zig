const std = @import("std");
const zon = @import("build.zig.zon");

const version = zon.version;
const BENCH_INDEXING_CWD = ".zig-cache/indexing-benchmark";

const grammar_sources = @import("src/grammar_sources.zig");
const GrammarSource = grammar_sources.GrammarSource;
const tree_sitter_source = grammar_sources.tree_sitter_source;
const grammars = grammar_sources.grammars;
const compiled_grammars = grammar_sources.compiled_grammars;

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
    addCurl(b, mod, target, optimize);
    addSqlite(b, mod);
    addUuid(b, mod, target, optimize);
    // Build options (version + embedded prompts)
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "prompt_md", @embedFile("priv/prompts/PROMPT.md"));
    build_options.addOption([]const u8, "agent_body", @embedFile("priv/agents/cog-code-query.md"));
    build_options.addOption([]const u8, "debug_agent_body", @embedFile("priv/agents/cog-debug.md"));
    build_options.addOption([]const u8, "mem_agent_body", @embedFile("priv/agents/cog-mem.md"));
    build_options.addOption([]const u8, "validate_agent_body", @embedFile("priv/agents/cog-mem-validate.md"));
    build_options.addOption([]const u8, "observe_agent_body", @embedFile("priv/agents/cog-observe.md"));
    build_options.addOption([]const u8, "opencode_override_plugin", @embedFile("priv/plugins/opencode-cog-override.ts"));
    build_options.addOption([]const u8, "opencode_memory_plugin", @embedFile("priv/plugins/opencode-cog-memory.ts"));
    build_options.addOption([]const u8, "opencode_debug_plugin", @embedFile("priv/plugins/opencode-cog-debug.ts"));
    build_options.addOption([]const u8, "claude_pretooluse_hook", @embedFile("priv/plugins/claude-cog-pretooluse.sh"));
    build_options.addOption([]const u8, "claude_stop_memory_hook", @embedFile("priv/plugins/claude-cog-stop-memory.sh"));
    build_options.addOption([]const u8, "claude_posttooluse_failure_hook", @embedFile("priv/plugins/claude-cog-posttooluse-failure.sh"));
    build_options.addOption([]const u8, "claude_precompact_hook", @embedFile("priv/plugins/claude-cog-precompact.sh"));
    build_options.addOption([]const u8, "gemini_before_tool_hook", @embedFile("priv/plugins/gemini-cog-before-tool.sh"));
    build_options.addOption([]const u8, "amp_cog_plugin", @embedFile("priv/plugins/amp-cog.ts"));
    build_options.addOption([]const u8, "pi_cog_extension", @embedFile("priv/plugins/pi-cog.ts"));
    build_options.addOption([]const u8, "bootstrap_prompt", @embedFile("priv/prompts/bootstrap.md"));
    build_options.addOption([]const u8, "bootstrap_associate_prompt", @embedFile("priv/prompts/bootstrap_associate.md"));
    build_options.addOption([]const u8, "project_scan_prompt", @embedFile("priv/prompts/project_scan.md"));
    const build_options_mod = build_options.createModule();

    mod.addImport("build_options", build_options_mod);

    // Executable
    const exe = b.addExecutable(.{
        .name = "cog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cog", .module = mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Code-sign on macOS for debug server (task_for_pid requires debugger entitlement)
    // Runs after the install step so the installed binary gets the entitlement.
    const codesign = b.addSystemCommand(&.{
        "codesign",                    "--entitlements", "debug-entitlements.plist", "-fs", "-",
        b.getInstallPath(.bin, "cog"),
    });
    codesign.step.dependOn(b.getInstallStep());

    const sign_step = b.step("sign", "Code-sign the binary with debug entitlements");
    sign_step.dependOn(&codesign.step);

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

    const grammar_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/grammar_sources.zig"),
            .target = b.graph.host,
        }),
    });
    const run_grammar_source_tests = b.addRunArtifact(grammar_source_tests);

    const verify_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_source.zig"),
            .target = b.graph.host,
        }),
    });
    const run_verify_source_tests = b.addRunArtifact(verify_source_tests);
    const verify_source_test_exe = b.addExecutable(.{
        .name = "verify-source-test-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_source.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const grammar_lock_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/grammar_lock.zig"),
            .target = b.graph.host,
        }),
    });
    const run_grammar_lock_tests = b.addRunArtifact(grammar_lock_tests);
    const grammar_lock_test_exe = b.addExecutable(.{
        .name = "grammar-lock-test-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/grammar_lock.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const fetch_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fetch_source.zig"),
            .target = b.graph.host,
        }),
    });
    const run_fetch_source_tests = b.addRunArtifact(fetch_source_tests);

    const live_mcp_client_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/live_mcp_client.zig"),
            .target = target,
        }),
    });
    const run_live_mcp_client_tests = b.addRunArtifact(live_mcp_client_tests);
    const live_mcp_client_test_step = b.step("test-live-mcp-client", "Test live MCP client contracts");
    live_mcp_client_test_step.dependOn(&run_live_mcp_client_tests.step);

    const standard_stream_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/standard_streams_test.zig"),
            .target = target,
        }),
    });
    const run_standard_stream_tests = b.addRunArtifact(standard_stream_tests);
    run_standard_stream_tests.setCwd(b.path("."));
    const standard_stream_test_step = b.step("test-standard-streams", "Test redirected standard-stream output");
    standard_stream_test_step.dependOn(&run_standard_stream_tests.step);

    const fetch_source_test_exe = b.addExecutable(.{
        .name = "fetch-source-test-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fetch_source.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const grammar_setup_tests = b.addSystemCommand(&.{ "sh", "test/grammar_setup.sh" });
    grammar_setup_tests.addFileArg(b.path("priv/grammar_setup.sh"));
    grammar_setup_tests.addFileArg(grammar_lock_test_exe.getEmittedBin());
    grammar_setup_tests.addFileArg(fetch_source_test_exe.getEmittedBin());
    grammar_setup_tests.addFileArg(verify_source_test_exe.getEmittedBin());
    grammar_setup_tests.addFileArg(b.path("build.zig"));

    // Windows cross-compilation gate. The credential boundary documents Windows
    // as fail-closed (`error.UnsupportedPlatform`), which is only meaningful if
    // the module still compiles for Windows — the POSIX store paths must stay
    // behind comptime guards. Compile-only: there is no Windows runner in CI.
    const windows_cross_step = b.step("test-windows-cross", "Compile the credential boundary for Windows (no execution)");
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const windows_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/credential_boundary.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = arch,
                    .os_tag = .windows,
                    .abi = .gnu,
                }),
                .optimize = .Debug,
            }),
        });
        windows_cross_step.dependOn(&windows_tests.step);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_grammar_source_tests.step);
    test_step.dependOn(&run_verify_source_tests.step);
    test_step.dependOn(&run_grammar_lock_tests.step);
    test_step.dependOn(&run_fetch_source_tests.step);
    test_step.dependOn(&run_live_mcp_client_tests.step);
    test_step.dependOn(&run_standard_stream_tests.step);
    test_step.dependOn(&grammar_setup_tests.step);
    test_step.dependOn(windows_cross_step);

    // Benchmark
    const bench_exe = b.addExecutable(.{
        .name = "bench-query",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_query.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addCurl(b, bench_exe.root_module, target, optimize);
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep()); // ensure cog binary is built
    const bench_step = b.step("bench", "Run query benchmark");
    bench_step.dependOn(&bench_run.step);
    if (b.args) |args| bench_run.addArgs(args);

    // Deterministic offline indexing benchmark and fuzz-smoke CI gate.
    const indexing_bench_exe = b.addExecutable(.{
        .name = "bench-indexing",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_indexing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cog", .module = mod }},
        }),
    });
    const prepare_indexing_bench = b.addSystemCommand(&.{ "mkdir", "-p", BENCH_INDEXING_CWD });
    const indexing_bench_run = b.addSystemCommand(&.{ "sh", "-c", "exec \"$1\"", "bench-indexing" });
    indexing_bench_run.addFileArg(indexing_bench_exe.getEmittedBin());
    indexing_bench_run.setCwd(.{ .cwd_relative = BENCH_INDEXING_CWD });
    indexing_bench_run.setEnvironmentVariable("COG_INDEX_BENCH_ROOT", b.pathFromRoot(BENCH_INDEXING_CWD));
    indexing_bench_run.setEnvironmentVariable("PWD", b.pathFromRoot(BENCH_INDEXING_CWD));
    indexing_bench_run.step.dependOn(&prepare_indexing_bench.step);
    indexing_bench_run.step.dependOn(&check_grammars.step);
    const indexing_bench_step = b.step("bench-indexing", "Run deterministic offline indexing benchmark");
    indexing_bench_step.dependOn(&indexing_bench_run.step);

    const indexing_gate_step = b.step("test-indexing-benchmark", "Run deterministic indexing benchmark and SCIP fuzz smoke");
    indexing_gate_step.dependOn(&indexing_bench_run.step);
    indexing_gate_step.dependOn(&run_mod_tests.step);

    // Integration test
    const integ_exe = b.addExecutable(.{
        .name = "test-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addCurl(b, integ_exe.root_module, target, optimize);
    live_mcp_client_test_step.dependOn(&bench_exe.step);
    live_mcp_client_test_step.dependOn(&integ_exe.step);
    const integ_run = b.addRunArtifact(integ_exe);
    integ_run.step.dependOn(b.getInstallStep());
    const integ_step = b.step("test-integration", "Run integration tests");
    integ_step.dependOn(&integ_run.step);
    if (b.args) |args| integ_run.addArgs(args);

    const indexing_integ_exe = b.addExecutable(.{
        .name = "test-indexing-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_indexing_integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const indexing_integ_run = b.addRunArtifact(indexing_integ_exe);
    indexing_integ_run.step.dependOn(b.getInstallStep());
    const indexing_integ_step = b.step("test-indexing-integration", "Run offline indexing integration tests");
    indexing_integ_step.dependOn(&indexing_integ_run.step);
    if (b.args) |args| indexing_integ_run.addArgs(args);

    const cli_state_exe = b.addExecutable(.{
        .name = "test-cli-state",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_cli_state.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const cli_state_run = b.addRunArtifact(cli_state_exe);
    cli_state_run.step.dependOn(b.getInstallStep());
    const cli_state_step = b.step("test-cli-state", "Verify read-only CLI commands do not create project state");
    cli_state_step.dependOn(&cli_state_run.step);
    test_step.dependOn(&cli_state_run.step);

    // Grammar check: compilation depends on it, setup does not
    exe.step.dependOn(&check_grammars.step);
    mod_tests.step.dependOn(&check_grammars.step);
    exe_tests.step.dependOn(&check_grammars.step);

    // Setup step (download grammars)
    const verify_source = b.addExecutable(.{
        .name = "verify-source",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/verify_source.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const grammar_lock = b.addExecutable(.{
        .name = "grammar-lock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/grammar_lock.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const fetch_source = b.addExecutable(.{
        .name = "fetch-source",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fetch_source.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    addSetupStep(b, verify_source, grammar_lock, fetch_source);

    // Release step
    const release_step = b.step("release", "Build release tarballs");
    addRelease(b, release_step, .aarch64, .macos, "darwin-arm64");
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
    for (compiled_grammars) |grammar| {
        mod.addIncludePath(b.path(b.fmt("grammars/{s}", .{grammar.name})));
    }

    // Disable Zig's UBSan for third-party C code: in ReleaseSafe Zig passes
    // -fsanitize=undefined -fsanitize-trap=undefined to Clang, which causes
    // trap instructions on technically-UB-but-works-in-practice C patterns
    // common in tree-sitter's generated parsers.
    const c_flags = &[_][]const u8{ "-std=gnu11", "-fno-exceptions", "-fno-sanitize=undefined" };

    // Tree-sitter core (unity build via lib.c)
    mod.addCSourceFile(.{
        .file = b.path("grammars/tree-sitter/src/lib.c"),
        .flags = c_flags,
    });

    for (compiled_grammars) |grammar| {
        mod.addCSourceFile(.{ .file = b.path(b.fmt("grammars/{s}/parser.c", .{grammar.name})), .flags = c_flags });
        if (grammar.has_scanner) {
            mod.addCSourceFile(.{ .file = b.path(b.fmt("grammars/{s}/scanner.c", .{grammar.name})), .flags = c_flags });
        }
    }
}

/// Add libcurl (with mbedTLS and zlib) to a module via the zig-curl package.
fn addCurl(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const curl_dep = b.dependency("curl", .{ .target = target, .optimize = optimize });
    mod.addImport("curl", curl_dep.module("curl"));
}

/// Add the vendored SQLite amalgamation to a module (with FTS5 enabled).
fn addSqlite(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("deps/sqlite"));
    const sqlite_flags: []const []const u8 = &.{
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_OMIT_DEPRECATED",
        "-DSQLITE_OMIT_SHARED_CACHE",
    };
    mod.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });
    mod.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3_helpers.c"),
        .flags = sqlite_flags,
    });
}

/// Add uuid-zig for v4 UUID generation.
fn addUuid(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const dep = b.dependency("uuid", .{ .target = target, .optimize = optimize });
    mod.addImport("uuid", dep.module("uuid"));
}

// Platform frameworks (CoreFoundation, CoreServices) are loaded dynamically
// at runtime via std.DynLib so cross-compilation works without macOS SDK stubs.

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
        .cpu_model = .baseline,
    });

    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = release_target,
        .link_libc = true,
    });
    addTreeSitter(b, release_mod);
    addCurl(b, release_mod, release_target, .ReleaseSafe);
    addSqlite(b, release_mod);
    addUuid(b, release_mod, release_target, .ReleaseSafe);
    const release_options = b.addOptions();
    release_options.addOption([]const u8, "version", version);
    release_options.addOption([]const u8, "prompt_md", @embedFile("priv/prompts/PROMPT.md"));
    release_options.addOption([]const u8, "agent_body", @embedFile("priv/agents/cog-code-query.md"));
    release_options.addOption([]const u8, "debug_agent_body", @embedFile("priv/agents/cog-debug.md"));
    release_options.addOption([]const u8, "mem_agent_body", @embedFile("priv/agents/cog-mem.md"));
    release_options.addOption([]const u8, "validate_agent_body", @embedFile("priv/agents/cog-mem-validate.md"));
    release_options.addOption([]const u8, "observe_agent_body", @embedFile("priv/agents/cog-observe.md"));
    release_options.addOption([]const u8, "opencode_override_plugin", @embedFile("priv/plugins/opencode-cog-override.ts"));
    release_options.addOption([]const u8, "opencode_memory_plugin", @embedFile("priv/plugins/opencode-cog-memory.ts"));
    release_options.addOption([]const u8, "opencode_debug_plugin", @embedFile("priv/plugins/opencode-cog-debug.ts"));
    release_options.addOption([]const u8, "claude_pretooluse_hook", @embedFile("priv/plugins/claude-cog-pretooluse.sh"));
    release_options.addOption([]const u8, "claude_stop_memory_hook", @embedFile("priv/plugins/claude-cog-stop-memory.sh"));
    release_options.addOption([]const u8, "claude_posttooluse_failure_hook", @embedFile("priv/plugins/claude-cog-posttooluse-failure.sh"));
    release_options.addOption([]const u8, "claude_precompact_hook", @embedFile("priv/plugins/claude-cog-precompact.sh"));
    release_options.addOption([]const u8, "gemini_before_tool_hook", @embedFile("priv/plugins/gemini-cog-before-tool.sh"));
    release_options.addOption([]const u8, "amp_cog_plugin", @embedFile("priv/plugins/amp-cog.ts"));
    release_options.addOption([]const u8, "pi_cog_extension", @embedFile("priv/plugins/pi-cog.ts"));
    release_options.addOption([]const u8, "bootstrap_prompt", @embedFile("priv/prompts/bootstrap.md"));
    release_options.addOption([]const u8, "bootstrap_associate_prompt", @embedFile("priv/prompts/bootstrap_associate.md"));
    release_options.addOption([]const u8, "project_scan_prompt", @embedFile("priv/prompts/project_scan.md"));
    const release_options_mod = release_options.createModule();

    release_mod.addImport("build_options", release_options_mod);

    const release_exe = b.addExecutable(.{
        .name = "cog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "cog", .module = release_mod },
                .{ .name = "build_options", .module = release_options_mod },
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

fn addSetupStep(
    b: *std.Build,
    verify_source: *std.Build.Step.Compile,
    grammar_lock: *std.Build.Step.Compile,
    fetch_source: *std.Build.Step.Compile,
) void {
    var script = std.ArrayList(u8).initCapacity(b.allocator, 32 * 1024) catch @panic("OOM");
    var writer = script.writer(b.allocator);
    writer.writeAll(
        \\set -eu
        \\VERIFY_SOURCE="$1"
        \\SETUP_LIB="$2"
        \\FETCH_SOURCE="$3"
        \\. "$SETUP_LIB"
        \\grammar_setup_init
        \\ARCHIVE="$WORKDIR/tree-sitter.tar.gz"
    ) catch @panic("OOM");
    writer.writeByte('\n') catch @panic("OOM");
    appendCoreSetup(&writer);

    var saw_typescript = false;
    for (grammars) |grammar| {
        if (std.mem.eql(u8, grammar.name, "typescript") or std.mem.eql(u8, grammar.name, "tsx")) {
            if (!saw_typescript) {
                appendTypescriptSetup(&writer, grammar);
                saw_typescript = true;
            }
        } else {
            appendGrammarSetup(&writer, grammar);
        }
    }

    writer.writeAll(
        \\grammar_setup_promote
        \\grammar_setup_finish
        \\echo "Installed verified tree-sitter grammar sources"
    ) catch @panic("OOM");

    const cmd = b.addSystemCommand(&.{"true"});
    cmd.argv.clearRetainingCapacity();
    cmd.addArtifactArg(grammar_lock);
    cmd.addArg(".");
    cmd.addArgs(&.{ "sh", "-c", script.items, "sh" });
    cmd.addFileArg(verify_source.getEmittedBin());
    cmd.addFileArg(b.path("priv/grammar_setup.sh"));
    cmd.addFileArg(fetch_source.getEmittedBin());
    const setup_step = b.step("setup", "Download and verify tree-sitter grammars");
    setup_step.dependOn(&cmd.step);
}

fn appendCoreSetup(writer: anytype) void {
    const source = tree_sitter_source;
    writer.print(
        \\grammar_setup_fetch_source "{s}" "{s}" "{s}" "$ARCHIVE" "$WORKDIR"
        \\EXTRACTED="$WORKDIR/tree-sitter-{s}"
        \\mkdir -p "$STAGING/tree-sitter/src" "$STAGING/tree-sitter/include"
        \\cp -R "$EXTRACTED/lib/src/"* "$STAGING/tree-sitter/src/"
        \\cp -R "$EXTRACTED/lib/include/"* "$STAGING/tree-sitter/include/"
        \\echo "Downloaded tree-sitter at {s}"
    , .{ source.repo, source.commit, source.archive_sha256, source.commit, source.commit }) catch @panic("OOM");
    writer.writeByte('\n') catch @panic("OOM");
}

fn appendGrammarSetup(writer: anytype, grammar: GrammarSource) void {
    const repo_name = std.fs.path.basename(grammar.repo);
    writer.print(
        \\ARCHIVE="$WORKDIR/{s}.tar.gz"
        \\grammar_setup_fetch_source "{s}" "{s}" "{s}" "$ARCHIVE" "$WORKDIR"
        \\EXTRACTED="$WORKDIR/{s}-{s}"
        \\mkdir -p "$STAGING/{s}/tree_sitter"
        \\cp "$EXTRACTED/{s}/parser.c" "$STAGING/{s}/parser.c"
    , .{ grammar.name, grammar.repo, grammar.commit, grammar.archive_sha256, repo_name, grammar.commit, grammar.name, grammar.src_prefix, grammar.name }) catch @panic("OOM");
    writer.writeByte('\n') catch @panic("OOM");

    if (grammar.has_scanner) {
        writer.print("cp \"$EXTRACTED/{s}/scanner.c\" \"$STAGING/{s}/scanner.c\"\n", .{ grammar.src_prefix, grammar.name }) catch @panic("OOM");
    }
    writer.print(
        \\cp "$EXTRACTED/{s}/tree_sitter/"*.h "$STAGING/{s}/tree_sitter/"
        \\if [ -f "$EXTRACTED/tags.scm" ]; then cp "$EXTRACTED/tags.scm" "$STAGING/{s}/tags.scm"; fi
        \\if [ -f "$EXTRACTED/{s}/tags.scm" ]; then cp "$EXTRACTED/{s}/tags.scm" "$STAGING/{s}/tags.scm"; fi
    , .{ grammar.src_prefix, grammar.name, grammar.name, grammar.src_prefix, grammar.src_prefix, grammar.name }) catch @panic("OOM");
    writer.writeByte('\n') catch @panic("OOM");

    if (std.mem.eql(u8, grammar.name, "yaml")) {
        writer.print(
            \\cp "$EXTRACTED/{s}/schema.core.c" "$STAGING/{s}/schema.core.c"
            \\cp "$EXTRACTED/{s}/schema.json.c" "$STAGING/{s}/schema.json.c"
            \\cp "$EXTRACTED/{s}/schema.legacy.c" "$STAGING/{s}/schema.legacy.c"
        , .{ grammar.src_prefix, grammar.name, grammar.src_prefix, grammar.name, grammar.src_prefix, grammar.name }) catch @panic("OOM");
        writer.writeByte('\n') catch @panic("OOM");
    } else if (std.mem.eql(u8, grammar.name, "rst")) {
        writer.print(
            \\mkdir -p "$STAGING/{s}/tree_sitter_rst"
            \\cp -R "$EXTRACTED/{s}/tree_sitter_rst/"* "$STAGING/{s}/tree_sitter_rst/"
        , .{ grammar.name, grammar.src_prefix, grammar.name }) catch @panic("OOM");
        writer.writeByte('\n') catch @panic("OOM");
    } else if (std.mem.eql(u8, grammar.name, "asciidoc")) {
        writer.print(
            \\mkdir -p "$STAGING/{s}/include"
            \\cp -R "$EXTRACTED/{s}/include/"* "$STAGING/{s}/include/"
        , .{ grammar.name, grammar.src_prefix, grammar.name }) catch @panic("OOM");
        writer.writeByte('\n') catch @panic("OOM");
    }
    writer.print("echo \"Downloaded {s} grammar at {s}\"\n", .{ grammar.name, grammar.commit }) catch @panic("OOM");
    writer.writeByte('\n') catch @panic("OOM");
}

fn appendTypescriptSetup(writer: anytype, source: GrammarSource) void {
    writer.print(
        \\ARCHIVE="$WORKDIR/typescript.tar.gz"
        \\grammar_setup_fetch_source "{s}" "{s}" "{s}" "$ARCHIVE" "$WORKDIR"
        \\EXTRACTED="$WORKDIR/tree-sitter-typescript-{s}"
        \\mkdir -p "$STAGING/typescript/tree_sitter" "$STAGING/tsx/tree_sitter" "$STAGING/common"
        \\cp "$EXTRACTED/typescript/src/parser.c" "$STAGING/typescript/parser.c"
        \\cp "$EXTRACTED/typescript/src/scanner.c" "$STAGING/typescript/scanner.c"
        \\cp "$EXTRACTED/typescript/src/tree_sitter/"*.h "$STAGING/typescript/tree_sitter/"
        \\if [ -f "$EXTRACTED/typescript/tags.scm" ]; then cp "$EXTRACTED/typescript/tags.scm" "$STAGING/typescript/tags.scm"; fi
        \\cp "$EXTRACTED/tsx/src/parser.c" "$STAGING/tsx/parser.c"
        \\cp "$EXTRACTED/tsx/src/scanner.c" "$STAGING/tsx/scanner.c"
        \\cp "$EXTRACTED/tsx/src/tree_sitter/"*.h "$STAGING/tsx/tree_sitter/"
        \\if [ -f "$EXTRACTED/tsx/tags.scm" ]; then cp "$EXTRACTED/tsx/tags.scm" "$STAGING/tsx/tags.scm"; fi
        \\cp "$EXTRACTED/common/scanner.h" "$STAGING/common/scanner.h"
        \\echo "Downloaded typescript/tsx grammars at {s}"
    , .{ source.repo, source.commit, source.archive_sha256, source.commit, source.commit }) catch @panic("OOM");
    writer.writeByte('\n') catch @panic("OOM");
}
