const std = @import("std");
const tui = @import("tui.zig");

// ── Agent Configuration Types ───────────────────────────────────────────

pub const PromptTarget = enum {
    claude_md,
    gemini_md,
    agents_md,
    copilot_instructions,

    pub fn filename(self: PromptTarget) []const u8 {
        return switch (self) {
            .claude_md => "CLAUDE.md",
            .gemini_md => "GEMINI.md",
            .agents_md => "AGENTS.md",
            .copilot_instructions => ".github/copilot-instructions.md",
        };
    }
};

pub const McpFormat = enum {
    json_mcpServers,
    json_servers,
    json_amp,
    json_mcp,
    toml,
    global_only,
};

pub const Agent = struct {
    id: []const u8,
    display_name: []const u8,
    prompt_target: PromptTarget,
    mcp_path: ?[]const u8,
    mcp_format: McpFormat,
    agent_file_path: ?[]const u8,
    agent_file_header: ?[]const u8,

    pub fn supportsToolPermissions(self: *const Agent) bool {
        return std.mem.eql(u8, self.id, "claude_code") or
            std.mem.eql(u8, self.id, "gemini") or
            std.mem.eql(u8, self.id, "amp");
    }
};

// ── Agent Registry ──────────────────────────────────────────────────────

pub const agents = [_]Agent{
    .{
        .id = "claude_code",
        .display_name = "Claude Code",
        .prompt_target = .claude_md,
        .mcp_path = ".mcp.json",
        .mcp_format = .json_mcpServers,
        .agent_file_path = ".claude/agents/cog-code-query.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\tools:
        \\  - Read
        \\  - Glob
        \\  - Grep
        \\mcpServers:
        \\  - cog
        \\model: haiku
        \\---
        \\
        ,
    },
    .{
        .id = "gemini",
        .display_name = "Gemini CLI",
        .prompt_target = .gemini_md,
        .mcp_path = ".gemini/settings.json",
        .mcp_format = .json_mcpServers,
        .agent_file_path = ".gemini/agents/cog-code-query.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\tools:
        \\  - read_file
        \\  - glob
        \\  - search_file_content
        \\---
        \\
        ,
    },
    .{
        .id = "copilot",
        .display_name = "GitHub Copilot",
        .prompt_target = .copilot_instructions,
        .mcp_path = ".vscode/mcp.json",
        .mcp_format = .json_servers,
        .agent_file_path = ".github/agents/cog-code-query.agent.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\tools:
        \\  - read
        \\  - search
        \\---
        \\
        ,
    },
    .{
        .id = "windsurf",
        .display_name = "Windsurf",
        .prompt_target = .agents_md,
        .mcp_path = null,
        .mcp_format = .global_only,
        .agent_file_path = ".windsurf/workflows/cog-code-query.md",
        .agent_file_header =
        \\---
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
    },
    .{
        .id = "cursor",
        .display_name = "Cursor",
        .prompt_target = .agents_md,
        .mcp_path = ".cursor/mcp.json",
        .mcp_format = .json_mcpServers,
        .agent_file_path = ".cursor/agents/cog-code-query.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\readonly: true
        \\---
        \\
        ,
    },
    .{
        .id = "codex",
        .display_name = "OpenAI Codex CLI",
        .prompt_target = .agents_md,
        .mcp_path = ".codex/config.toml",
        .mcp_format = .toml,
        .agent_file_path = ".codex/config.toml",
        .agent_file_header = null,
    },
    .{
        .id = "amp",
        .display_name = "Amp",
        .prompt_target = .agents_md,
        .mcp_path = ".amp/settings.json",
        .mcp_format = .json_amp,
        .agent_file_path = ".agents/skills/cog-code-query.md",
        .agent_file_header =
        \\---
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
    },
    .{
        .id = "goose",
        .display_name = "Goose",
        .prompt_target = .agents_md,
        .mcp_path = null,
        .mcp_format = .global_only,
        .agent_file_path = ".goose/cog-code-query.yaml",
        .agent_file_header =
        \\---
        \\title: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
    },
    .{
        .id = "roo",
        .display_name = "Roo Code",
        .prompt_target = .agents_md,
        .mcp_path = ".roo/mcp.json",
        .mcp_format = .json_mcpServers,
        .agent_file_path = ".roomodes",
        .agent_file_header = null,
    },
    .{
        .id = "opencode",
        .display_name = "OpenCode",
        .prompt_target = .agents_md,
        .mcp_path = "opencode.json",
        .mcp_format = .json_mcp,
        .agent_file_path = ".opencode/agents/cog-code-query.md",
        .agent_file_header =
        \\---
        \\description: Explore code structure using the Cog SCIP index
        \\mode: subagent
        \\tools:
        \\  write: false
        \\  edit: false
        \\---
        \\
        ,
    },
};

pub fn toMenuItems() [agents.len]tui.MenuItem {
    var items: [agents.len]tui.MenuItem = undefined;
    for (agents, 0..) |agent, i| {
        items[i] = .{ .label = agent.display_name };
    }
    return items;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "agent count" {
    try std.testing.expectEqual(@as(usize, 10), agents.len);
}

test "toMenuItems" {
    const items = toMenuItems();
    try std.testing.expectEqualStrings("Claude Code", items[0].label);
    try std.testing.expectEqualStrings("OpenCode", items[9].label);
}

test "PromptTarget.filename" {
    try std.testing.expectEqualStrings("CLAUDE.md", PromptTarget.claude_md.filename());
    try std.testing.expectEqualStrings("GEMINI.md", PromptTarget.gemini_md.filename());
    try std.testing.expectEqualStrings("AGENTS.md", PromptTarget.agents_md.filename());
    try std.testing.expectEqualStrings(".github/copilot-instructions.md", PromptTarget.copilot_instructions.filename());
}

test "supportsToolPermissions" {
    // Supported agents
    try std.testing.expect(agents[0].supportsToolPermissions()); // claude_code
    try std.testing.expect(agents[1].supportsToolPermissions()); // gemini
    try std.testing.expect(agents[6].supportsToolPermissions()); // amp

    // Unsupported agents
    try std.testing.expect(!agents[2].supportsToolPermissions()); // copilot
    try std.testing.expect(!agents[3].supportsToolPermissions()); // windsurf
    try std.testing.expect(!agents[4].supportsToolPermissions()); // cursor
    try std.testing.expect(!agents[5].supportsToolPermissions()); // codex
    try std.testing.expect(!agents[7].supportsToolPermissions()); // goose
    try std.testing.expect(!agents[8].supportsToolPermissions()); // roo
    try std.testing.expect(!agents[9].supportsToolPermissions()); // opencode
}

test "mcp strategy coverage stays explicit" {
    var local_count: usize = 0;
    var global_only_count: usize = 0;

    for (agents) |agent| {
        if (agent.mcp_format == .global_only) {
            global_only_count += 1;
            try std.testing.expect(agent.mcp_path == null);
        } else {
            local_count += 1;
            try std.testing.expect(agent.mcp_path != null);
        }
    }

    try std.testing.expectEqual(@as(usize, 8), local_count);
    try std.testing.expectEqual(@as(usize, 2), global_only_count);
}
