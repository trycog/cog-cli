pub const config = @import("config.zig");
pub const client = @import("client.zig");
pub const commands = @import("commands.zig");
pub const tui = @import("tui.zig");
pub const protobuf = @import("protobuf.zig");
pub const scip = @import("scip.zig");
pub const scip_encode = @import("scip_encode.zig");
pub const code_intel = @import("code_intel.zig");
pub const settings = @import("settings.zig");
pub const paths = @import("paths.zig");
pub const extensions = @import("extensions.zig");
pub const help_text = @import("help_text.zig");
pub const debug = @import("debug.zig");
pub const curl = @import("curl.zig");
pub const tree_sitter_indexer = @import("tree_sitter_indexer.zig");

test {
    _ = config;
    _ = client;
    _ = commands;
    _ = tui;
    _ = protobuf;
    _ = scip;
    _ = scip_encode;
    _ = code_intel;
    _ = settings;
    _ = paths;
    _ = extensions;
    _ = help_text;
    _ = debug;
    _ = curl;
    _ = tree_sitter_indexer;
}
