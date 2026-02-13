const std = @import("std");
const config_mod = @import("cog").config;
const commands = @import("cog").commands;

const Config = config_mod.Config;

const usage_text =
    \\cog - CLI for Cog associative memory
    \\
    \\Usage: cog <command> [options]
    \\
    \\Setup:
    \\  init            Interactive setup — verify key, pick brain, write .cog.json
    \\
    \\Commands:
    \\  recall          Search memory for relevant concepts
    \\  get             Retrieve a specific engram by ID
    \\  connections     List connections from an engram
    \\  trace           Find reasoning path between two concepts
    \\  bulk-recall     Search with multiple queries
    \\  list-short-term List short-term memories pending consolidation
    \\  stale           List synapses approaching staleness
    \\  stats           Get brain statistics
    \\  orphans         List disconnected concepts
    \\  connectivity    Analyze graph connectivity
    \\  list-terms      List all engram terms
    \\
    \\  learn           Store a new concept
    \\  associate       Link two concepts
    \\  bulk-learn      Batch store concepts
    \\  bulk-associate  Batch link concepts
    \\  update          Update an existing engram
    \\  unlink          Remove a synapse
    \\  refactor        Update concept via term lookup
    \\  deprecate       Mark a concept as obsolete
    \\  reinforce       Consolidate short-term to long-term
    \\  flush           Delete a short-term memory
    \\  verify          Confirm synapse accuracy
    \\  meld            Create cross-brain connection
    \\
    \\Run 'cog <command> --help' for details on a specific command.
    \\
;

pub fn main() void {
    mainInner() catch {
        std.process.exit(1);
    };
}

fn mainInner() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect args
    var args_list: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer args_list.deinit(allocator);

    var iter = std.process.args();
    while (iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printStdout(usage_text);
        return;
    }

    const subcmd: []const u8 = args[1];
    const cmd_args = args[2..];

    // Handle --help at top level
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "help")) {
        printStdout(usage_text);
        return;
    }

    // Handle init command (doesn't need config)
    if (std.mem.eql(u8, subcmd, "init")) {
        try commands.init(allocator, cmd_args);
        return;
    }

    // Validate command before loading config
    const command = resolveCommand(subcmd) orelse {
        printErr("error: unknown command '");
        printErr(subcmd);
        printErr("'\n\n");
        printStdout(usage_text);
        return error.Explained;
    };

    // Load config
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    // Dispatch
    try command(allocator, cmd_args, cfg);
}

const CommandFn = *const fn (std.mem.Allocator, []const [:0]const u8, Config) anyerror!void;

fn resolveCommand(name: []const u8) ?CommandFn {
    const map = .{
        .{ "recall", commands.recall },
        .{ "get", commands.get },
        .{ "connections", commands.connections },
        .{ "trace", commands.trace },
        .{ "bulk-recall", commands.bulkRecall },
        .{ "list-short-term", commands.listShortTerm },
        .{ "stale", commands.stale },
        .{ "stats", commands.stats },
        .{ "orphans", commands.orphans },
        .{ "connectivity", commands.connectivity },
        .{ "list-terms", commands.listTerms },
        .{ "learn", commands.learn },
        .{ "associate", commands.associate },
        .{ "bulk-learn", commands.bulkLearn },
        .{ "bulk-associate", commands.bulkAssociate },
        .{ "update", commands.update },
        .{ "unlink", commands.unlink },
        .{ "refactor", commands.refactor },
        .{ "deprecate", commands.deprecate },
        .{ "reinforce", commands.reinforce },
        .{ "flush", commands.flush },
        .{ "verify", commands.verify },
        .{ "meld", commands.meld },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn printStdout(text: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
}

fn printErr(msg: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}
