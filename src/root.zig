pub const config = @import("config.zig");
pub const client = @import("client.zig");
pub const commands = @import("commands.zig");
pub const tui = @import("tui.zig");

test {
    _ = config;
    _ = client;
    _ = commands;
    _ = tui;
}
