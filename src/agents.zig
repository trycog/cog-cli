const std = @import("std");
const tui = @import("tui.zig");
const agent_usage = @import("agent_usage.zig");

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

pub const SubAgentSupport = enum {
    dedicated_files,
    shared_config,
    workflow_files,
};

pub const CapabilityLevel = enum {
    none,
    prompt_only,
    config,
    runtime,
};

pub const AgentCapabilities = struct {
    repo_local_mcp: bool,
    auto_tool_permissions: bool,
    runtime_policy_plugins: bool,
    dedicated_subagent_files: bool,
    subagent_support: SubAgentSupport,
    code_query_enforcement: CapabilityLevel,
    debug_enforcement: CapabilityLevel,
    memory_enforcement: CapabilityLevel,
    context_packaging: bool,
    memory_write_enrichment: CapabilityLevel,
};

const gemini_code_query_tools =
    \\tools:
    \\  - cog__code_explore
    \\  - cog__code_query
    \\  - read_file
;

const gemini_debug_tools =
    \\tools:
    \\  - cog__debug_launch
    \\  - cog__debug_breakpoint
    \\  - cog__debug_run
    \\  - cog__debug_inspect
    \\  - cog__debug_stacktrace
    \\  - cog__debug_stop
    \\  - cog__debug_sessions
    \\  - cog__debug_scopes
    \\  - cog__code_query
    \\  - cog__code_explore
    \\  - cog__mem_recall
    \\  - cog__mem_bulk_recall
    \\  - read_file
    \\  - run_shell_command
;

const gemini_memory_tools =
    \\tools:
    \\  - cog__mem_recall
    \\  - cog__mem_bulk_recall
    \\  - cog__mem_trace
    \\  - cog__mem_connections
    \\  - cog__mem_get
    \\  - cog__mem_list_short_term
    \\  - cog__mem_reinforce
    \\  - cog__mem_flush
    \\  - cog__mem_stale
    \\  - cog__mem_verify
    \\  - cog__mem_stats
    \\  - cog__mem_orphans
    \\  - cog__mem_connectivity
    \\  - cog__mem_list_terms
    \\  - cog__mem_unlink
    \\  - cog__mem_meld
    \\  - cog__mem_bulk_learn
    \\  - cog__mem_bulk_associate
;

const copilot_code_query_tools =
    \\tools:
    \\  - cog/code_explore
    \\  - cog/code_query
    \\  - read
;

const copilot_debug_tools =
    \\tools:
    \\  - cog/debug_launch
    \\  - cog/debug_breakpoint
    \\  - cog/debug_run
    \\  - cog/debug_inspect
    \\  - cog/debug_stacktrace
    \\  - cog/debug_stop
    \\  - cog/debug_sessions
    \\  - cog/debug_scopes
    \\  - cog/code_explore
    \\  - cog/code_query
    \\  - cog/mem_recall
    \\  - cog/mem_bulk_recall
    \\  - read
    \\  - execute
;

const copilot_memory_tools =
    \\tools:
    \\  - cog/mem_recall
    \\  - cog/mem_bulk_recall
    \\  - cog/mem_trace
    \\  - cog/mem_connections
    \\  - cog/mem_get
    \\  - cog/mem_list_short_term
    \\  - cog/mem_reinforce
    \\  - cog/mem_flush
    \\  - cog/mem_stale
    \\  - cog/mem_verify
    \\  - cog/mem_stats
    \\  - cog/mem_orphans
    \\  - cog/mem_connectivity
    \\  - cog/mem_list_terms
    \\  - cog/mem_unlink
    \\  - cog/mem_meld
    \\  - cog/mem_bulk_learn
    \\  - cog/mem_bulk_associate
;

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

    pub fn capabilities(self: *const Agent) AgentCapabilities {
        if (std.mem.eql(u8, self.id, "claude_code")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = true,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .code_query_enforcement = .config,
                .debug_enforcement = .config,
                .memory_enforcement = .config,
                .context_packaging = true,
                .memory_write_enrichment = .config,
            };
        }

        if (std.mem.eql(u8, self.id, "gemini")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = true,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .code_query_enforcement = .config,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .config,
            };
        }

        if (std.mem.eql(u8, self.id, "copilot")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .code_query_enforcement = .prompt_only,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "windsurf")) {
            return .{
                .repo_local_mcp = false,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .workflow_files,
                .code_query_enforcement = .prompt_only,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "cursor")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .code_query_enforcement = .prompt_only,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "codex")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = false,
                .subagent_support = .shared_config,
                .code_query_enforcement = .prompt_only,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "amp")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = true,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .code_query_enforcement = .config,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .config,
            };
        }

        if (std.mem.eql(u8, self.id, "goose")) {
            return .{
                .repo_local_mcp = false,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .workflow_files,
                .code_query_enforcement = .prompt_only,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "roo")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = false,
                .subagent_support = .shared_config,
                .code_query_enforcement = .prompt_only,
                .debug_enforcement = .prompt_only,
                .memory_enforcement = .prompt_only,
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "opencode")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = true,
                .runtime_policy_plugins = true,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .code_query_enforcement = .runtime,
                .debug_enforcement = .runtime,
                .memory_enforcement = .runtime,
                .context_packaging = true,
                .memory_write_enrichment = .runtime,
            };
        }

        unreachable;
    }

    pub fn supportsToolPermissions(self: *const Agent) bool {
        return self.capabilities().auto_tool_permissions;
    }

    pub fn overrideEnforcementLevel(self: *const Agent) OverrideEnforcementLevel {
        const caps = self.capabilities();
        if (caps.runtime_policy_plugins) return .medium;
        if (caps.code_query_enforcement == .config and
            caps.debug_enforcement == .config and
            caps.memory_enforcement == .config) return .hard;
        if (caps.code_query_enforcement == .config or
            caps.debug_enforcement == .config or
            caps.memory_enforcement == .config) return .medium;
        return .soft;
    }

    pub fn toolPermissionsSummary(self: *const Agent) []const u8 {
        return if (self.capabilities().auto_tool_permissions) "Auto-allow" else "";
    }

    pub fn mcpConfigSummary(self: *const Agent) []const u8 {
        return switch (self.mcp_format) {
            .global_only => "Global config",
            else => self.mcp_path orelse "",
        };
    }

    pub fn subAgentsSummary(self: *const Agent) []const u8 {
        return if (self.agent_file_path != null and self.debug_file_path != null and self.mem_file_path != null) "Yes" else "";
    }

    pub fn contextPackagingSummary(self: *const Agent) []const u8 {
        return if (self.capabilities().context_packaging) "Yes" else "";
    }

    pub fn memoryEnrichmentSummary(self: *const Agent) []const u8 {
        return switch (self.capabilities().memory_write_enrichment) {
            .runtime => "Runtime reminders",
            .config => "Hook/config reminders",
            .prompt_only => "Prompt guidance",
            .none => "",
        };
    }

    pub fn overrideSummary(self: *const Agent) []const u8 {
        const caps = self.capabilities();

        if (caps.runtime_policy_plugins) {
            return "Medium runtime plugins + sub-agent permissions";
        }

        if (caps.subagent_support == .workflow_files) {
            return "Soft workflow runbooks";
        }

        if (std.mem.eql(u8, self.id, "roo")) {
            return "Medium native mode groups";
        }

        if (std.mem.eql(u8, self.id, "codex")) {
            return "Soft shared-config specialist guidance";
        }

        if (std.mem.eql(u8, self.id, "cursor")) {
            return "Soft prompt guidance + read-only specialists";
        }

        if (std.mem.eql(u8, self.id, "copilot")) {
            return "Soft specialist tool scoping";
        }

        if (std.mem.eql(u8, self.id, "claude_code")) {
            return "Hard sub-agent allowlist + hooks";
        }

        if (std.mem.eql(u8, self.id, "gemini")) {
            return "Medium hooks + sub-agent tool scoping";
        }

        if (caps.code_query_enforcement == .config and
            caps.debug_enforcement == .config and
            caps.memory_enforcement == .config)
        {
            return "Hard sub-agent allowlist";
        }

        if (caps.code_query_enforcement == .config or
            caps.debug_enforcement == .config or
            caps.memory_enforcement == .config)
        {
            if (std.mem.eql(u8, self.id, "amp")) {
                return "Medium permission bootstrap + skills + plugin";
            }
            return "Medium sub-agent tool scoping";
        }

        return "Soft prompt guidance";
    }

    pub fn supportMatrixRow(self: *const Agent, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "| {s} | `{s}` | {s} | {s} | {s} | {s} | {s} |", .{
            self.display_name,
            self.mcpConfigSummary(),
            self.subAgentsSummary(),
            self.toolPermissionsSummary(),
            self.overrideSummary(),
            self.contextPackagingSummary(),
            self.memoryEnrichmentSummary(),
        });
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
        \\  - mcp__cog__debug_launch
        \\  - mcp__cog__debug_breakpoint
        \\  - mcp__cog__debug_run
        \\  - mcp__cog__debug_inspect
        \\  - mcp__cog__debug_stacktrace
        \\  - mcp__cog__debug_stop
        \\  - mcp__cog__debug_threads
        \\  - mcp__cog__debug_scopes
        \\  - mcp__cog__debug_set_variable
        \\  - mcp__cog__debug_watchpoint
        \\  - mcp__cog__debug_exception_info
        \\  - mcp__cog__debug_attach
        \\  - mcp__cog__debug_restart
        \\  - mcp__cog__debug_sessions
        \\  - mcp__cog__debug_poll_events
        \\  - mcp__cog__code_query
        \\  - mcp__cog__code_explore
        \\  - mcp__cog__mem_recall
        \\  - mcp__cog__mem_bulk_recall
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
        \\  - mcp__cog__mem_recall
        \\  - mcp__cog__mem_bulk_recall
        \\  - mcp__cog__mem_trace
        \\  - mcp__cog__mem_connections
        \\  - mcp__cog__mem_get
        \\  - mcp__cog__mem_list_short_term
        \\  - mcp__cog__mem_reinforce
        \\  - mcp__cog__mem_flush
        \\  - mcp__cog__mem_stale
        \\  - mcp__cog__mem_verify
        \\  - mcp__cog__mem_stats
        \\  - mcp__cog__mem_orphans
        \\  - mcp__cog__mem_connectivity
        \\  - mcp__cog__mem_list_terms
        \\  - mcp__cog__mem_unlink
        \\  - mcp__cog__mem_meld
        \\  - mcp__cog__mem_bulk_learn
        \\  - mcp__cog__mem_bulk_associate
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
    ++ gemini_code_query_tools ++
        \\---
        \\
        ,
    .debug_file_path = ".gemini/agents/cog-debug.md",
        .debug_file_header = 
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
    ++ gemini_debug_tools ++
        \\max_turns: 15
        \\---
        \\
        ,
    .mem_file_path = ".gemini/agents/cog-mem.md",
        .mem_file_header = 
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
    ++ gemini_memory_tools ++
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
    ++ copilot_code_query_tools ++
        \\---
        \\
        ,
    .debug_file_path = ".github/agents/cog-debug.agent.md",
        .debug_file_header = 
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
    ++ copilot_debug_tools ++
        \\user-invokable: false
        \\---
        \\
        ,
    .mem_file_path = ".github/agents/cog-mem.agent.md",
        .mem_file_header = 
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
    ++ copilot_memory_tools ++
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
        \\readonly: true
        \\---
        \\
        ,
        .mem_file_path = ".cursor/agents/cog-mem.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\readonly: true
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
        .agent_file_path = ".agents/skills/cog-code-query/SKILL.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
        .debug_file_path = ".agents/skills/cog-debug/SKILL.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".agents/skills/cog-mem/SKILL.md",
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
        \\permission:
        \\  read: allow
        \\  glob: deny
        \\  grep: deny
        \\  list: deny
        \\  bash: deny
        \\  webfetch: deny
        \\  task: deny
        \\  cog_*: allow
        \\tools:
        \\  write: false
        \\  edit: false
        \\---
        \\
        ,
        .mem_file_path = ".opencode/agents/cog-mem.md",
        .mem_file_header =
        \\---
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\mode: subagent
        \\permission:
        \\  read: deny
        \\  glob: deny
        \\  grep: deny
        \\  list: deny
        \\  bash: deny
        \\  webfetch: deny
        \\  task: deny
        \\  cog_*: allow
        \\tools:
        \\  write: false
        \\  edit: false
        \\---
        \\
        ,
    },
};

pub const MenuEntry = struct {
    agent_index: usize,
    item: tui.MenuItem,
};

fn agentLessThan(counts: *const agent_usage.Counts, lhs_index: usize, rhs_index: usize) bool {
    const lhs = agents[lhs_index];
    const rhs = agents[rhs_index];
    const lhs_count = agent_usage.countFor(counts, lhs.id);
    const rhs_count = agent_usage.countFor(counts, rhs.id);
    if (lhs_count != rhs_count) return lhs_count > rhs_count;
    return std.mem.order(u8, lhs.display_name, rhs.display_name) == .lt;
}

fn buildMenuEntriesFromCounts(counts: *const agent_usage.Counts) [agents.len]MenuEntry {
    var sorted_indices: [agents.len]usize = undefined;
    for (0..agents.len) |i| sorted_indices[i] = i;

    var i: usize = 1;
    while (i < sorted_indices.len) : (i += 1) {
        const current = sorted_indices[i];
        var j = i;
        while (j > 0 and agentLessThan(counts, current, sorted_indices[j - 1])) : (j -= 1) {
            sorted_indices[j] = sorted_indices[j - 1];
        }
        sorted_indices[j] = current;
    }

    var entries: [agents.len]MenuEntry = undefined;
    for (sorted_indices, 0..) |agent_index, idx| {
        entries[idx] = .{
            .agent_index = agent_index,
            .item = .{ .label = agents[agent_index].display_name },
        };
    }
    return entries;
}

pub fn buildMenuEntries(allocator: std.mem.Allocator) ![agents.len]MenuEntry {
    var counts = try agent_usage.loadCounts(allocator);
    defer agent_usage.deinitCounts(allocator, &counts);
    return buildMenuEntriesFromCounts(&counts);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "agent count" {
    try std.testing.expectEqual(@as(usize, 10), agents.len);
}

test "buildMenuEntries sorts alphabetically by default" {
    var counts = agent_usage.Counts.init(std.testing.allocator);
    defer counts.deinit();
    const entries = buildMenuEntriesFromCounts(&counts);
    try std.testing.expectEqualStrings("Amp", entries[0].item.label);
    try std.testing.expectEqualStrings("Windsurf", entries[9].item.label);
}

test "buildMenuEntries prioritizes higher selection counts" {
    var counts = agent_usage.Counts.init(std.testing.allocator);
    defer agent_usage.deinitCounts(std.testing.allocator, &counts);
    try counts.put(try std.testing.allocator.dupe(u8, "opencode"), 4);
    try counts.put(try std.testing.allocator.dupe(u8, "amp"), 2);
    const entries = buildMenuEntriesFromCounts(&counts);
    try std.testing.expectEqualStrings("OpenCode", entries[0].item.label);
    try std.testing.expectEqualStrings("Amp", entries[1].item.label);
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

test "capability model matches mcp strategy" {
    for (agents) |agent| {
        const caps = agent.capabilities();
        try std.testing.expectEqual(agent.mcp_path != null, caps.repo_local_mcp);
    }
}

test "capability model keeps subagent topology explicit" {
    try std.testing.expect(agents[3].capabilities().subagent_support == .workflow_files); // windsurf
    try std.testing.expect(agents[5].capabilities().subagent_support == .shared_config); // codex
    try std.testing.expect(agents[8].capabilities().subagent_support == .shared_config); // roo
    try std.testing.expect(agents[9].capabilities().subagent_support == .dedicated_files); // opencode
    try std.testing.expectEqualStrings(".agents/skills/cog-code-query/SKILL.md", agents[6].agent_file_path.?); // amp
    try std.testing.expectEqualStrings(".agents/skills/cog-debug/SKILL.md", agents[6].debug_file_path.?); // amp
    try std.testing.expectEqualStrings(".agents/skills/cog-mem/SKILL.md", agents[6].mem_file_path.?); // amp

    for (agents) |agent| {
        const caps = agent.capabilities();
        if (caps.subagent_support == .dedicated_files or caps.subagent_support == .workflow_files) {
            try std.testing.expect(caps.dedicated_subagent_files);
        } else {
            try std.testing.expect(!caps.dedicated_subagent_files);
        }
    }
}

test "runtime policy plugins stay opencode-only" {
    var runtime_plugin_agents: usize = 0;
    for (agents) |agent| {
        if (agent.capabilities().runtime_policy_plugins) {
            runtime_plugin_agents += 1;
            try std.testing.expectEqualStrings("opencode", agent.id);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), runtime_plugin_agents);
}

test "tool permission support stays capability-driven" {
    for (agents) |agent| {
        try std.testing.expectEqual(agent.capabilities().auto_tool_permissions, agent.supportsToolPermissions());
    }
}

test "enforcement level stays capability-driven" {
    try std.testing.expect(agents[0].capabilities().code_query_enforcement == .config);
    try std.testing.expect(agents[0].capabilities().debug_enforcement == .config);
    try std.testing.expect(agents[0].capabilities().memory_enforcement == .config);

    try std.testing.expect(agents[9].capabilities().code_query_enforcement == .runtime);
    try std.testing.expect(agents[9].capabilities().debug_enforcement == .runtime);
    try std.testing.expect(agents[9].capabilities().memory_enforcement == .runtime);

    try std.testing.expect(agents[2].capabilities().code_query_enforcement == .prompt_only);
    try std.testing.expect(agents[2].capabilities().debug_enforcement == .prompt_only);
    try std.testing.expect(agents[2].capabilities().memory_enforcement == .prompt_only);

    try std.testing.expect(agents[0].capabilities().memory_write_enrichment == .config);
    try std.testing.expect(agents[6].capabilities().memory_write_enrichment == .config);
    try std.testing.expect(agents[9].capabilities().memory_write_enrichment == .runtime);
    try std.testing.expect(agents[2].capabilities().memory_write_enrichment == .prompt_only);

    for (agents) |agent| {
        try std.testing.expect(agent.capabilities().context_packaging);
    }
}

test "code-query headers prefer cog-first exploration" {
    const claude_header = agents[0].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "Glob") == null);
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "Grep") == null);

    const gemini_header = agents[1].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, gemini_header, "cog__code_explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_header, "cog__code_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_header, "glob") == null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_header, "search_file_content") == null);

    const copilot_header = agents[2].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, copilot_header, "cog/code_explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_header, "cog/code_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_header, "cog/*") == null);

    const opencode_header = agents[9].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, opencode_header, "glob: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_header, "grep: deny") != null);
}

test "opencode mem header stays memory-only" {
    const opencode_mem_header = agents[9].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, opencode_mem_header, "read: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_mem_header, "task: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_mem_header, "cog_*: allow") != null);
}

test "opencode debug header stays debugger-focused" {
    const opencode_debug_header = agents[9].debug_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "read: allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "glob: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "bash: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "cog_*: allow") != null);
}

test "cursor specialist headers stay read-only" {
    const cursor_debug_header = agents[4].debug_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, cursor_debug_header, "readonly: true") != null);

    const cursor_mem_header = agents[4].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, cursor_mem_header, "readonly: true") != null);
}

test "gemini specialist headers stay capability-aligned" {
    try std.testing.expect(std.mem.eql(u8, gemini_code_query_tools,
        \\tools:
        \\  - cog__code_explore
        \\  - cog__code_query
        \\  - read_file
    ));

    const gemini_debug_header = agents[1].debug_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, gemini_debug_header, "cog__debug_sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_debug_header, "cog__mem_bulk_recall") != null);

    const gemini_mem_header = agents[1].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, gemini_mem_header, "cog__mem_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_mem_header, "cog__mem_bulk_associate") != null);
}

test "copilot specialist headers stay capability-aligned" {
    try std.testing.expect(std.mem.eql(u8, copilot_code_query_tools,
        \\tools:
        \\  - cog/code_explore
        \\  - cog/code_query
        \\  - read
    ));

    const copilot_debug_header = agents[2].debug_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, copilot_debug_header, "cog/debug_sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_debug_header, "cog/mem_bulk_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_debug_header, "cog/*") == null);

    const copilot_mem_header = agents[2].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, copilot_mem_header, "cog/mem_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_mem_header, "cog/mem_bulk_associate") != null);
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

test "support summaries stay capability-driven" {
    try std.testing.expectEqualStrings("Auto-allow", agents[0].toolPermissionsSummary());
    try std.testing.expectEqualStrings("", agents[2].toolPermissionsSummary());

    try std.testing.expectEqualStrings("Hard sub-agent allowlist + hooks", agents[0].overrideSummary());
    try std.testing.expectEqualStrings("Medium hooks + sub-agent tool scoping", agents[1].overrideSummary());
    try std.testing.expectEqualStrings("Soft specialist tool scoping", agents[2].overrideSummary());
    try std.testing.expectEqualStrings("Soft workflow runbooks", agents[3].overrideSummary());
    try std.testing.expectEqualStrings("Soft prompt guidance + read-only specialists", agents[4].overrideSummary());
    try std.testing.expectEqualStrings("Soft shared-config specialist guidance", agents[5].overrideSummary());
    try std.testing.expectEqualStrings("Medium permission bootstrap + skills + plugin", agents[6].overrideSummary());
    try std.testing.expectEqualStrings("Soft workflow runbooks", agents[7].overrideSummary());
    try std.testing.expectEqualStrings("Medium native mode groups", agents[8].overrideSummary());
    try std.testing.expectEqualStrings("Medium runtime plugins + sub-agent permissions", agents[9].overrideSummary());
}

test "support matrix helpers stay aligned" {
    try std.testing.expectEqualStrings(".mcp.json", agents[0].mcpConfigSummary());
    try std.testing.expectEqualStrings("Global config", agents[3].mcpConfigSummary());
    try std.testing.expectEqualStrings("Yes", agents[9].subAgentsSummary());
    try std.testing.expectEqualStrings("Yes", agents[0].contextPackagingSummary());
    try std.testing.expectEqualStrings("Runtime reminders", agents[9].memoryEnrichmentSummary());

    const opencode_row = try agents[9].supportMatrixRow(std.testing.allocator);
    defer std.testing.allocator.free(opencode_row);
    try std.testing.expectEqualStrings(
        "| OpenCode | `opencode.json` | Yes | Auto-allow | Medium runtime plugins + sub-agent permissions | Yes | Runtime reminders |",
        opencode_row,
    );

    const goose_row = try agents[7].supportMatrixRow(std.testing.allocator);
    defer std.testing.allocator.free(goose_row);
    try std.testing.expectEqualStrings(
        "| Goose | `Global config` | Yes |  | Soft workflow runbooks | Yes | Prompt guidance |",
        goose_row,
    );
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
