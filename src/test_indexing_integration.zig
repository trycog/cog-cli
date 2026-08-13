const std = @import("std");
const scip = @import("scip.zig");

const COG_BINARY = "zig-out/bin/cog";
const TEST_ROOT = ".zig-cache/indexing-integration";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn getCogPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, COG_BINARY });
}

fn recreateTestRoot() !void {
    if (std.fs.cwd().access(TEST_ROOT, .{})) {
        std.fs.cwd().deleteTree(TEST_ROOT) catch |err| return err;
    } else |_| {}
    try std.fs.cwd().makePath(TEST_ROOT);
}

fn writeFile(rel_path: []const u8, content: []const u8) !void {
    const full_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ TEST_ROOT, rel_path });
    defer std.heap.page_allocator.free(full_path);
    if (std.fs.path.dirname(full_path)) |dir_name| {
        try std.fs.cwd().makePath(dir_name);
    }
    const file = try std.fs.cwd().createFile(full_path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn runCog(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = TEST_ROOT,
        .max_output_bytes = 256 * 1024,
    });
}

fn expectSuccess(step: []const u8, result: std.process.Child.RunResult) void {
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
            fail(
                "{s} failed with exit code {d}\nstdout:\n{s}\nstderr:\n{s}\n",
                .{ step, code, result.stdout, result.stderr },
            );
        },
        else => fail(
            "{s} terminated unexpectedly\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ step, result.stdout, result.stderr },
        ),
    }
}

fn expectContains(step: []const u8, haystack: []const u8, needle: []const u8) void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    fail("{s} missing `{s}`\noutput:\n{s}\n", .{ step, needle, haystack });
}

fn indexHasSymbol(index: *const scip.Index, rel_path: []const u8, symbol_name: []const u8) bool {
    for (index.documents) |doc| {
        if (!std.mem.eql(u8, doc.relative_path, rel_path)) continue;
        for (doc.symbols) |sym| {
            if (std.mem.eql(u8, sym.display_name, symbol_name)) return true;
        }
    }
    return false;
}

fn indexHasSymbolKind(index: *const scip.Index, rel_path: []const u8, symbol_name: []const u8, kind: i32) bool {
    for (index.documents) |doc| {
        if (!std.mem.eql(u8, doc.relative_path, rel_path)) continue;
        for (doc.symbols) |sym| {
            if (std.mem.eql(u8, sym.display_name, symbol_name) and sym.kind == kind) return true;
        }
    }
    return false;
}

fn indexHasOccurrence(index: *const scip.Index, rel_path: []const u8, symbol: []const u8) bool {
    for (index.documents) |doc| {
        if (!std.mem.eql(u8, doc.relative_path, rel_path)) continue;
        for (doc.occurrences) |occ| {
            if (std.mem.eql(u8, occ.symbol, symbol)) return true;
        }
    }
    return false;
}

fn indexHasDocument(index: *const scip.Index, rel_path: []const u8) bool {
    for (index.documents) |doc| {
        if (std.mem.eql(u8, doc.relative_path, rel_path)) return true;
    }
    return false;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cog_path = try getCogPath(allocator);
    defer allocator.free(cog_path);

    try recreateTestRoot();

    try writeFile("apps/cedalio_dozer/assets/js/app.js",
        \\export function helper() {
        \\  return 42;
        \\}
        \\
        \\export function appEntry() {
        \\  service.helper();
        \\}
        \\
        \\export class AppShell {}
    );
    try writeFile("pkg/main.go",
        \\package main
        \\
        \\func goHello() {}
    );
    try writeFile("src/helpers.py",
        \\def py_helper():
        \\    return 1
    );
    try writeFile("src/types.ts",
        \\export interface WidgetProps {
        \\  count: number;
        \\}
    );
    try writeFile("src/view.tsx",
        \\export function DashboardView() {
        \\  return <section>ok</section>;
        \\}
    );
    try writeFile("src/lib.rs",
        \\fn new() {}
        \\fn rust_helper() { new(); }
    );
    try writeFile("src/Main.java",
        \\import java.util.List;
        \\class Main {
        \\    private int count;
        \\    Main() { javaHelper(); }
        \\    void javaHelper() {}
        \\    void run() { this.javaHelper(); }
        \\}
    );
    try writeFile("src/native.c",
        \\void c_helper(void) {}
        \\void c_run(void) { c_helper(); }
    );
    try writeFile("src/native.cpp",
        \\class Widget { public: void work() {} };
        \\void cppHelper() {}
        \\void cppRun(Widget &widget) { cppHelper(); widget.work(); }
    );
    try writeFile("notes/doc.md",
        \\# Hello
        \\
        \\This is an indexed markdown file.
    );

    const index_result = try runCog(allocator, &.{
        cog_path,
        "code:index",
        "**/*.js",
        "**/*.go",
        "**/*.py",
        "**/*.ts",
        "**/*.tsx",
        "**/*.rs",
        "**/*.java",
        "**/*.c",
        "**/*.cpp",
        "**/*.md",
    });
    defer allocator.free(index_result.stdout);
    defer allocator.free(index_result.stderr);
    expectSuccess("cog code:index", index_result);

    const index_path = TEST_ROOT ++ "/.cog/index.scip";
    std.fs.cwd().access(index_path, .{}) catch fail("missing index file `{s}`\n", .{index_path});

    const encoded = try std.fs.cwd().readFileAlloc(allocator, index_path, 16 * 1024 * 1024);
    defer allocator.free(encoded);
    var index = try scip.decode(allocator, encoded);
    defer scip.freeIndex(allocator, &index);

    if (!indexHasSymbol(&index, "apps/cedalio_dozer/assets/js/app.js", "appEntry")) {
        fail("decoded index missing JS symbol `appEntry`\n", .{});
    }
    if (!indexHasSymbol(&index, "apps/cedalio_dozer/assets/js/app.js", "AppShell")) {
        fail("decoded index missing JS symbol `AppShell`\n", .{});
    }
    if (!indexHasSymbol(&index, "pkg/main.go", "goHello")) {
        fail("decoded index missing Go symbol `goHello`\n", .{});
    }
    if (!indexHasDocument(&index, "src/view.tsx")) {
        fail("decoded index missing TSX document `src/view.tsx`\n", .{});
    }
    if (!indexHasOccurrence(&index, "apps/cedalio_dozer/assets/js/app.js", "cog/call/helper")) {
        fail("decoded index missing JavaScript member call `helper`\n", .{});
    }
    if (!indexHasSymbolKind(&index, "src/Main.java", "Main", 9)) {
        fail("decoded index missing Java constructor `Main`\n", .{});
    }
    if (!indexHasSymbolKind(&index, "src/Main.java", "count", 15)) {
        fail("decoded index missing Java field `count`\n", .{});
    }
    if (!indexHasOccurrence(&index, "src/Main.java", "cog/import/java.util.List")) {
        fail("decoded index missing Java import `java.util.List`\n", .{});
    }
    if (!indexHasOccurrence(&index, "src/Main.java", "cog/call/javaHelper")) {
        fail("decoded index missing Java call `javaHelper`\n", .{});
    }
    if (!indexHasOccurrence(&index, "src/native.c", "cog/call/c_helper")) {
        fail("decoded index missing C call `c_helper`\n", .{});
    }
    if (!indexHasOccurrence(&index, "src/native.cpp", "cog/call/cppHelper") or
        !indexHasOccurrence(&index, "src/native.cpp", "cog/call/work"))
    {
        fail("decoded index missing C++ free or member call\n", .{});
    }
    if (!indexHasSymbol(&index, "src/lib.rs", "new") or
        !indexHasOccurrence(&index, "src/lib.rs", "cog/call/new"))
    {
        fail("decoded index missing valid Rust `new` symbol or call\n", .{});
    }

    std.debug.print("indexing integration test passed\n", .{});
}
