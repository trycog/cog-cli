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

pub const OverrideEnforcementLevel = enum {
    hard,
    medium,
    soft,
};

pub const Agent = struct {
    id: []const u8,
    display_name: []const u8,
    prompt_target: PromptTarget,
    mcp_path: ?[]const u8,
    mcp_format: McpFormat,
    agent_file_path: ?[]const u8,
    agent_file_header: ?[]const u8,
    debug_file_path: ?[]const u8,
    debug_file_header: ?[]const u8,
    mem_file_path: ?[]const u8,
    mem_file_header: ?[]const u8,

    pub fn supportsToolPermissions(self: *const Agent) bool {
        return std.mem.eql(u8, self.id, "claude_code") or
            std.mem.eql(u8, self.id, "gemini") or
            std.mem.eql(u8, self.id, "amp") or
            std.mem.eql(u8, self.id, "opencode");
    }

    pub fn overrideEnforcementLevel(self: *const Agent) OverrideEnforcementLevel {
        if (std.mem.eql(u8, self.id, "claude_code")) return .hard;
        if (std.mem.eql(u8, self.id, "gemini") or
            std.mem.eql(u8, self.id, "amp") or
            std.mem.eql(u8, self.id, "opencode")) return .medium;
        return .soft;
    }
};

// ── Agent Registry ──────────────────────────────────────────────────────

pub const agents = [_]Agent{
    // ── Claude Code ─────────────────────────────────────────────────
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
        \\mcpServers:
        \\  - cog
        \\model: haiku
        \\---
        \\
        ,
        .debug_file_path = ".claude/agents/cog-debug.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\tools:
        \\  - mcp__cog__cog_debug_launch
        \\  - mcp__cog__cog_debug_breakpoint
        \\  - mcp__cog__cog_debug_run
        \\  - mcp__cog__cog_debug_inspect
        \\  - mcp__cog__cog_debug_stacktrace
        \\  - mcp__cog__cog_debug_stop
        \\  - mcp__cog__cog_debug_threads
        \\  - mcp__cog__cog_debug_scopes
        \\  - mcp__cog__cog_debug_set_variable
        \\  - mcp__cog__cog_debug_watchpoint
        \\  - mcp__cog__cog_debug_exception_info
        \\  - mcp__cog__cog_debug_attach
        \\  - mcp__cog__cog_debug_restart
        \\  - mcp__cog__cog_debug_sessions
        \\  - mcp__cog__cog_debug_poll_events
        \\  - mcp__cog__cog_code_query
        \\  - mcp__cog__cog_code_explore
        \\  - mcp__cog__cog_mem_recall
        \\  - mcp__cog__cog_mem_bulk_recall
        \\  - Read
        \\  - Bash
        \\mcpServers:
        \\  - cog
        \\maxTurns: 15
        \\---
        \\
        ,
        .mem_file_path = ".claude/agents/cog-mem.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\tools:
        \\  - mcp__cog__cog_mem_recall
        \\  - mcp__cog__cog_mem_bulk_recall
        \\  - mcp__cog__cog_mem_trace
        \\  - mcp__cog__cog_mem_connections
        \\  - mcp__cog__cog_mem_get
        \\  - mcp__cog__cog_mem_list_short_term
        \\  - mcp__cog__cog_mem_reinforce
        \\  - mcp__cog__cog_mem_flush
        \\  - mcp__cog__cog_mem_stale
        \\  - mcp__cog__cog_mem_verify
        \\  - mcp__cog__cog_mem_stats
        \\  - mcp__cog__cog_mem_orphans
        \\  - mcp__cog__cog_mem_connectivity
        \\  - mcp__cog__cog_mem_list_terms
        \\  - mcp__cog__cog_mem_unlink
        \\  - mcp__cog__cog_mem_meld
        \\  - mcp__cog__cog_mem_bulk_learn
        \\  - mcp__cog__cog_mem_bulk_associate
        \\mcpServers:
        \\  - cog
        \\---
        \\
        ,
    },
    // ── Gemini CLI ──────────────────────────────────────────────────
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
        \\---
        \\
        ,
        .debug_file_path = ".gemini/agents/cog-debug.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\tools:
        \\  - cog__cog_debug_launch
        \\  - cog__cog_debug_breakpoint
        \\  - cog__cog_debug_run
        \\  - cog__cog_debug_inspect
        \\  - cog__cog_debug_stacktrace
        \\  - cog__cog_debug_stop
        \\  - cog__cog_code_query
        \\  - cog__cog_code_explore
        \\  - cog__cog_mem_recall
        \\  - read_file
        \\  - run_shell_command
        \\max_turns: 15
        \\---
        \\
        ,
        .mem_file_path = ".gemini/agents/cog-mem.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
    },
    // ── GitHub Copilot ──────────────────────────────────────────────
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
        \\  - cog/*
        \\  - read
        \\---
        \\
        ,
        .debug_file_path = ".github/agents/cog-debug.agent.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\tools:
        \\  - cog/*
        \\  - read
        \\  - execute
        \\user-invokable: false
        \\---
        \\
        ,
        .mem_file_path = ".github/agents/cog-mem.agent.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\tools:
        \\  - cog/*
        \\user-invokable: false
        \\---
        \\
        ,
    },
    // ── Windsurf ────────────────────────────────────────────────────
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
        .debug_file_path = ".windsurf/workflows/cog-debug.md",
        .debug_file_header =
        \\---
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".windsurf/workflows/cog-mem.md",
        .mem_file_header =
        \\---
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
    },
    // ── Cursor ──────────────────────────────────────────────────────
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
        .debug_file_path = ".cursor/agents/cog-debug.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".cursor/agents/cog-mem.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
    },
    // ── OpenAI Codex CLI ────────────────────────────────────────────
    .{
        .id = "codex",
        .display_name = "OpenAI Codex CLI",
        .prompt_target = .agents_md,
        .mcp_path = ".codex/config.toml",
        .mcp_format = .toml,
        .agent_file_path = ".codex/config.toml",
        .agent_file_header = null,
        .debug_file_path = ".codex/config.toml",
        .debug_file_header = null,
        .mem_file_path = ".codex/config.toml",
        .mem_file_header = null,
    },
    // ── Amp ─────────────────────────────────────────────────────────
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
        .debug_file_path = ".agents/skills/cog-debug.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".agents/skills/cog-mem.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
    },
    // ── Goose ───────────────────────────────────────────────────────
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
        .debug_file_path = ".goose/cog-debug.yaml",
        .debug_file_header =
        \\---
        \\title: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".goose/cog-mem.yaml",
        .mem_file_header =
        \\---
        \\title: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
    },
    // ── Roo Code ────────────────────────────────────────────────────
    .{
        .id = "roo",
        .display_name = "Roo Code",
        .prompt_target = .agents_md,
        .mcp_path = ".roo/mcp.json",
        .mcp_format = .json_mcpServers,
        .agent_file_path = ".roomodes",
        .agent_file_header = null,
        .debug_file_path = ".roomodes",
        .debug_file_header = null,
        .mem_file_path = ".roomodes",
        .mem_file_header = null,
    },
    // ── OpenCode ────────────────────────────────────────────────────
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
        \\permission:
        \\  read: allow
        \\  glob: deny
        \\  grep: deny
        \\  cog_*: allow
        \\tools:
        \\  write: false
        \\  edit: false
        \\---
        \\
        ,
        .debug_file_path = ".opencode/agents/cog-debug.md",
        .debug_file_header =
        \\---
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\mode: subagent
        \\---
        \\
        ,
        .mem_file_path = ".opencode/agents/cog-mem.md",
        .mem_file_header =
        \\---
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\mode: subagent
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
    try std.testing.expect(agents[9].supportsToolPermissions()); // opencode

    // Unsupported agents
    try std.testing.expect(!agents[2].supportsToolPermissions()); // copilot
    try std.testing.expect(!agents[3].supportsToolPermissions()); // windsurf
    try std.testing.expect(!agents[4].supportsToolPermissions()); // cursor
    try std.testing.expect(!agents[5].supportsToolPermissions()); // codex
    try std.testing.expect(!agents[7].supportsToolPermissions()); // goose
    try std.testing.expect(!agents[8].supportsToolPermissions()); // roo
}

test "overrideEnforcementLevel" {
    try std.testing.expect(agents[0].overrideEnforcementLevel() == .hard);
    try std.testing.expect(agents[1].overrideEnforcementLevel() == .medium);
    try std.testing.expect(agents[6].overrideEnforcementLevel() == .medium);
    try std.testing.expect(agents[9].overrideEnforcementLevel() == .medium);

    try std.testing.expect(agents[2].overrideEnforcementLevel() == .soft);
    try std.testing.expect(agents[3].overrideEnforcementLevel() == .soft);
    try std.testing.expect(agents[4].overrideEnforcementLevel() == .soft);
    try std.testing.expect(agents[5].overrideEnforcementLevel() == .soft);
    try std.testing.expect(agents[7].overrideEnforcementLevel() == .soft);
    try std.testing.expect(agents[8].overrideEnforcementLevel() == .soft);
}

test "code-query headers prefer cog-first exploration" {
    const claude_header = agents[0].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "Glob") == null);
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "Grep") == null);

    const gemini_header = agents[1].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, gemini_header, "glob") == null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_header, "search_file_content") == null);

    const copilot_header = agents[2].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, copilot_header, "cog/*") != null);

    const opencode_header = agents[9].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, opencode_header, "glob: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_header, "grep: deny") != null);
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

test "all agents have debug_file_path" {
    for (agents) |agent| {
        try std.testing.expect(agent.debug_file_path != null);
    }
}

test "all agents have mem_file_path" {
    for (agents) |agent| {
        try std.testing.expect(agent.mem_file_path != null);
    }
}
