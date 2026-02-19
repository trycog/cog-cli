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

pub const HooksFormat = enum {
    claude_code,
    gemini,
    windsurf,
    cursor,
    amp,
    none,
};

pub const Agent = struct {
    id: []const u8,
    display_name: []const u8,
    prompt_target: PromptTarget,
    skill_dir: ?[]const u8,
    mcp_path: ?[]const u8,
    mcp_format: McpFormat,
    hooks_path: ?[]const u8,
    hooks_format: HooksFormat,
};

// ── Agent Registry ──────────────────────────────────────────────────────

pub const agents = [_]Agent{
    .{
        .id = "claude_code",
        .display_name = "Claude Code",
        .prompt_target = .claude_md,
        .skill_dir = ".claude/skills",
        .mcp_path = ".mcp.json",
        .mcp_format = .json_mcpServers,
        .hooks_path = ".claude/settings.json",
        .hooks_format = .claude_code,
    },
    .{
        .id = "gemini",
        .display_name = "Gemini CLI",
        .prompt_target = .gemini_md,
        .skill_dir = ".gemini/skills",
        .mcp_path = ".gemini/settings.json",
        .mcp_format = .json_mcpServers,
        .hooks_path = ".gemini/settings.json",
        .hooks_format = .gemini,
    },
    .{
        .id = "copilot",
        .display_name = "GitHub Copilot",
        .prompt_target = .copilot_instructions,
        .skill_dir = ".claude/skills",
        .mcp_path = ".vscode/mcp.json",
        .mcp_format = .json_servers,
        .hooks_path = ".claude/settings.json",
        .hooks_format = .claude_code,
    },
    .{
        .id = "windsurf",
        .display_name = "Windsurf",
        .prompt_target = .agents_md,
        .skill_dir = ".codeium/windsurf/skills",
        .mcp_path = null,
        .mcp_format = .global_only,
        .hooks_path = ".windsurf/hooks.json",
        .hooks_format = .windsurf,
    },
    .{
        .id = "cursor",
        .display_name = "Cursor",
        .prompt_target = .agents_md,
        .skill_dir = null,
        .mcp_path = ".cursor/mcp.json",
        .mcp_format = .json_mcpServers,
        .hooks_path = ".cursor/hooks.json",
        .hooks_format = .cursor,
    },
    .{
        .id = "codex",
        .display_name = "OpenAI Codex CLI",
        .prompt_target = .agents_md,
        .skill_dir = ".agents/skills",
        .mcp_path = ".codex/config.toml",
        .mcp_format = .toml,
        .hooks_path = null,
        .hooks_format = .none,
    },
    .{
        .id = "amp",
        .display_name = "Amp",
        .prompt_target = .agents_md,
        .skill_dir = ".agents/skills",
        .mcp_path = ".amp/settings.json",
        .mcp_format = .json_amp,
        .hooks_path = ".amp/settings.json",
        .hooks_format = .amp,
    },
    .{
        .id = "goose",
        .display_name = "Goose",
        .prompt_target = .agents_md,
        .skill_dir = null,
        .mcp_path = null,
        .mcp_format = .global_only,
        .hooks_path = null,
        .hooks_format = .none,
    },
    .{
        .id = "roo",
        .display_name = "Roo Code",
        .prompt_target = .agents_md,
        .skill_dir = ".roo/skills",
        .mcp_path = ".roo/mcp.json",
        .mcp_format = .json_mcpServers,
        .hooks_path = null,
        .hooks_format = .none,
    },
    .{
        .id = "opencode",
        .display_name = "OpenCode",
        .prompt_target = .agents_md,
        .skill_dir = ".config/opencode/skills",
        .mcp_path = "opencode.json",
        .mcp_format = .json_mcp,
        .hooks_path = null,
        .hooks_format = .none,
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
