const std = @import("std");
const tui = @import("tui.zig");
const agent_usage = @import("agent_usage.zig");
const debug_log = @import("debug_log.zig");

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
    json_pi,
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

pub const SpecialistKind = enum {
    code_query,
    debug,
    memory,
    validate,
    observe,
};

pub const SpecialistCapabilities = struct {
    code_query: CapabilityLevel = .none,
    debug: CapabilityLevel = .none,
    memory: CapabilityLevel = .none,
    validate: CapabilityLevel = .none,
    observe: CapabilityLevel = .none,

    pub fn level(self: SpecialistCapabilities, kind: SpecialistKind) CapabilityLevel {
        return switch (kind) {
            .code_query => self.code_query,
            .debug => self.debug,
            .memory => self.memory,
            .validate => self.validate,
            .observe => self.observe,
        };
    }

    pub fn supports(self: SpecialistCapabilities, kind: SpecialistKind) bool {
        return self.level(kind) != .none;
    }

    pub fn availability(self: SpecialistCapabilities, memory_enabled: bool) SpecialistAvailability {
        return .{
            .code_query = self.code_query != .none,
            .debug = self.debug != .none,
            .memory = memory_enabled and self.memory != .none,
            .validate = memory_enabled and self.validate != .none,
            .observe = self.observe != .none,
        };
    }
};

pub const SpecialistAvailability = struct {
    code_query: bool = false,
    debug: bool = false,
    memory: bool = false,
    validate: bool = false,
    observe: bool = false,

    pub fn all() SpecialistAvailability {
        return .{
            .code_query = true,
            .debug = true,
            .memory = true,
            .validate = true,
            .observe = true,
        };
    }

    pub fn has(self: SpecialistAvailability, kind: SpecialistKind) bool {
        return switch (kind) {
            .code_query => self.code_query,
            .debug => self.debug,
            .memory => self.memory,
            .validate => self.validate,
            .observe => self.observe,
        };
    }

    pub fn set(self: *SpecialistAvailability, kind: SpecialistKind, value: bool) void {
        switch (kind) {
            .code_query => self.code_query = value,
            .debug => self.debug = value,
            .memory => self.memory = value,
            .validate => self.validate = value,
            .observe => self.observe = value,
        }
    }

    pub fn intersect(self: *SpecialistAvailability, other: SpecialistAvailability) void {
        self.code_query = self.code_query and other.code_query;
        self.debug = self.debug and other.debug;
        self.memory = self.memory and other.memory;
        self.validate = self.validate and other.validate;
        self.observe = self.observe and other.observe;
    }
};

pub const AgentCapabilities = struct {
    repo_local_mcp: bool,
    auto_tool_permissions: bool,
    runtime_policy_plugins: bool,
    dedicated_subagent_files: bool,
    subagent_support: SubAgentSupport,
    specialists: SpecialistCapabilities,
    context_packaging: bool,
    memory_write_enrichment: CapabilityLevel,
};

const gemini_observe_tools =
    \\tools:
    \\  - cog__observe_start
    \\  - cog__observe_stop
    \\  - cog__observe_events
    \\  - cog__observe_causal_chains
    \\  - cog__observe_query
    \\  - cog__observe_sessions
    \\  - cog__observe_status
    \\  - cog__code_explore
    \\  - cog__code_query
    \\  - cog__mem_recall
    \\  - read_file
    \\  - run_shell_command
;

const copilot_observe_tools =
    \\tools:
    \\  - cog/observe_start
    \\  - cog/observe_stop
    \\  - cog/observe_events
    \\  - cog/observe_causal_chains
    \\  - cog/observe_query
    \\  - cog/observe_sessions
    \\  - cog/observe_status
    \\  - cog/code_explore
    \\  - cog/code_query
    \\  - cog/mem_recall
    \\  - read
    \\  - execute
;

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
    \\  - read_file
    \\  - run_shell_command
;

const gemini_memory_tools =
    \\tools:
    \\  - cog__mem_recall
    \\  - cog__code_explore
    \\  - cog__code_query
    \\  - cog__mem_trace
    \\  - cog__mem_connections
    \\  - cog__mem_get
    \\  - cog__mem_learn
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
    \\  - cog__mem_associate
    \\  - cog__mem_refactor
    \\  - cog__mem_update
    \\  - cog__mem_deprecate
    \\  - read_file
;

const gemini_validate_tools =
    \\tools:
    \\  - cog__mem_learn
    \\  - cog__mem_associate
    \\  - cog__mem_refactor
    \\  - cog__mem_update
    \\  - cog__mem_deprecate
    \\  - cog__mem_list_short_term
    \\  - cog__mem_reinforce
    \\  - cog__mem_flush
    \\  - cog__mem_verify
;

const copilot_validate_tools =
    \\tools:
    \\  - cog/mem_learn
    \\  - cog/mem_associate
    \\  - cog/mem_refactor
    \\  - cog/mem_update
    \\  - cog/mem_deprecate
    \\  - cog/mem_list_short_term
    \\  - cog/mem_reinforce
    \\  - cog/mem_flush
    \\  - cog/mem_verify
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
    \\  - read
    \\  - execute
;

const copilot_memory_tools =
    \\tools:
    \\  - cog/mem_recall
    \\  - cog/code_explore
    \\  - cog/code_query
    \\  - cog/mem_trace
    \\  - cog/mem_connections
    \\  - cog/mem_get
    \\  - cog/mem_learn
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
    \\  - cog/mem_associate
    \\  - cog/mem_refactor
    \\  - cog/mem_update
    \\  - cog/mem_deprecate
    \\  - read
;

// ── Shared Cog-first policy (single source for every host surface) ──────

/// The only narrow exceptions under which a host may fall back from Cog code
/// intelligence to raw text search. Every instruction surface quotes these
/// exceptions verbatim so no host drifts to a looser or stricter policy.
pub const raw_text_fallback_exceptions =
    "the Cog index is unavailable, incomplete for the target code, or the task is about raw string literals, log messages, or other non-symbol text patterns";

/// The Cog-first exploration mandate as rendered in every host prompt.
pub const cog_first_exploration_policy =
    "Do NOT use Grep, Glob, or shell search commands like `grep`, `rg`, `find`, or `git grep` for code exploration when the Cog index is available.";

/// The raw-text fallback policy as rendered in every host prompt.
pub const prompt_raw_text_fallback_policy =
    "Only fall back to Grep, Glob, or shell search commands when " ++ raw_text_fallback_exceptions ++ ".";

/// The raw-text fallback policy as rendered in specialist instructions.
pub const specialist_raw_text_fallback_policy =
    "Only fall back to raw file search when " ++ raw_text_fallback_exceptions ++ ".";

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
    validate_file_path: ?[]const u8 = null,
    validate_file_header: ?[]const u8 = null,
    observe_file_path: ?[]const u8 = null,
    observe_file_header: ?[]const u8 = null,

    pub fn observeFilePath(self: *const Agent, observe_enabled: bool) ?[]const u8 {
        return if (observe_enabled) self.observe_file_path else null;
    }

    pub fn observeFileHeader(self: *const Agent, observe_enabled: bool) ?[]const u8 {
        return if (observe_enabled) self.observe_file_header else null;
    }

    pub fn capabilities(self: *const Agent) AgentCapabilities {
        if (std.mem.eql(u8, self.id, "claude_code")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = true,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .dedicated_files,
                .specialists = .{
                    .code_query = .config,
                    .debug = .config,
                    .memory = .config,
                    .validate = .config,
                    .observe = .config,
                },
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
                .specialists = .{
                    .code_query = .config,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .config,
                    .observe = .prompt_only,
                },
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
                .specialists = .{
                    .code_query = .prompt_only,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .prompt_only,
                    .observe = .prompt_only,
                },
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
                .specialists = .{
                    .code_query = .prompt_only,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .prompt_only,
                    .observe = .prompt_only,
                },
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
                .subagent_support = .workflow_files,
                .specialists = .{
                    .code_query = .prompt_only,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .prompt_only,
                    .observe = .prompt_only,
                },
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
                .specialists = .{
                    .code_query = .prompt_only,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .prompt_only,
                    .observe = .prompt_only,
                },
                .context_packaging = true,
                .memory_write_enrichment = .prompt_only,
            };
        }

        if (std.mem.eql(u8, self.id, "amp")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = true,
                .runtime_policy_plugins = true,
                .dedicated_subagent_files = true,
                .subagent_support = .workflow_files,
                .specialists = .{
                    .code_query = .runtime,
                    .debug = .prompt_only,
                    .memory = .runtime,
                    .validate = .runtime,
                    .observe = .prompt_only,
                },
                .context_packaging = true,
                .memory_write_enrichment = .runtime,
            };
        }

        if (std.mem.eql(u8, self.id, "goose")) {
            return .{
                .repo_local_mcp = false,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = false,
                .dedicated_subagent_files = true,
                .subagent_support = .workflow_files,
                .specialists = .{
                    .code_query = .prompt_only,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .prompt_only,
                    .observe = .prompt_only,
                },
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
                .specialists = .{
                    .code_query = .prompt_only,
                    .debug = .prompt_only,
                    .memory = .prompt_only,
                    .validate = .prompt_only,
                    .observe = .prompt_only,
                },
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
                .specialists = .{
                    .code_query = .runtime,
                    .debug = .runtime,
                    .memory = .runtime,
                    .validate = .runtime,
                    .observe = .runtime,
                },
                .context_packaging = true,
                .memory_write_enrichment = .runtime,
            };
        }

        if (std.mem.eql(u8, self.id, "pi")) {
            return .{
                .repo_local_mcp = true,
                .auto_tool_permissions = false,
                .runtime_policy_plugins = true,
                .dedicated_subagent_files = true,
                .subagent_support = .workflow_files,
                .specialists = .{
                    .code_query = .runtime,
                    .debug = .prompt_only,
                    .memory = .runtime,
                    .validate = .runtime,
                    .observe = .prompt_only,
                },
                .context_packaging = true,
                .memory_write_enrichment = .runtime,
            };
        }

        unreachable;
    }

    pub fn specialistPath(self: *const Agent, kind: SpecialistKind) ?[]const u8 {
        if (!self.capabilities().specialists.supports(kind)) return null;
        return switch (kind) {
            .code_query => self.agent_file_path,
            .debug => self.debug_file_path,
            .memory => self.mem_file_path,
            .validate => self.validate_file_path,
            .observe => self.observe_file_path,
        };
    }

    pub fn specialistHeader(self: *const Agent, kind: SpecialistKind) ?[]const u8 {
        if (!self.capabilities().specialists.supports(kind)) return null;
        return switch (kind) {
            .code_query => self.agent_file_header,
            .debug => self.debug_file_header,
            .memory => self.mem_file_header,
            .validate => self.validate_file_header,
            .observe => self.observe_file_header,
        };
    }

    pub fn supportsToolPermissions(self: *const Agent) bool {
        return self.capabilities().auto_tool_permissions;
    }

    pub fn overrideEnforcementLevel(self: *const Agent) OverrideEnforcementLevel {
        const caps = self.capabilities();
        if (caps.runtime_policy_plugins) return .medium;
        if (caps.specialists.code_query == .config and
            caps.specialists.debug == .config and
            caps.specialists.memory == .config) return .hard;
        if (caps.specialists.code_query == .config or
            caps.specialists.debug == .config or
            caps.specialists.memory == .config) return .medium;
        return .soft;
    }

    pub fn toolPermissionsSummary(self: *const Agent) []const u8 {
        return if (self.capabilities().auto_tool_permissions) "Auto-allow" else "";
    }

    /// Detect if this agent appears to be in use in the current project by
    /// checking for agent-specific files. We deliberately skip prompt_target
    /// (CLAUDE.md, AGENTS.md, etc.) because those are shared across agents —
    /// e.g. Cursor also reads CLAUDE.md, and AMP/Windsurf/OpenCode all use AGENTS.md.
    pub fn isDetectedInCwd(self: *const Agent) bool {
        const hooks = @import("hooks.zig");
        // Check MCP config file (unique per agent)
        if (self.mcp_path) |path| {
            if (self.mcp_format != .global_only and hooks.fileExistsInCwd(path)) return true;
        }
        // Check cog sub-agent files (unique per agent)
        if (self.agent_file_path) |path| {
            if (hooks.fileExistsInCwd(path)) return true;
        }
        return false;
    }

    pub fn mcpConfigSummary(self: *const Agent) []const u8 {
        return switch (self.mcp_format) {
            .global_only => "Global config",
            else => self.mcp_path orelse "",
        };
    }

    pub fn subAgentsSummary(self: *const Agent) []const u8 {
        inline for (std.meta.tags(SpecialistKind)) |kind| {
            if (!self.capabilities().specialists.supports(kind) or self.specialistPath(kind) == null) return "";
        }
        return "Yes";
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

        if (std.mem.eql(u8, self.id, "pi")) {
            return "Medium extension hooks + skills";
        }

        if (caps.runtime_policy_plugins) {
            return "Medium runtime plugins + sub-agent permissions";
        }

        if (std.mem.eql(u8, self.id, "windsurf")) {
            return "Soft skills + rules";
        }

        if (std.mem.eql(u8, self.id, "goose")) {
            return "Soft skill guidance";
        }

        if (std.mem.eql(u8, self.id, "roo")) {
            return "Medium native mode groups";
        }

        if (std.mem.eql(u8, self.id, "codex")) {
            return "Soft shared-config specialist guidance";
        }

        if (std.mem.eql(u8, self.id, "cursor")) {
            return "Soft AGENTS.md + project rules";
        }

        if (std.mem.eql(u8, self.id, "copilot")) {
            return "Soft specialist tool scoping";
        }

        if (std.mem.eql(u8, self.id, "claude_code")) {
            // Init also approves the project-scoped MCP server for Claude via
            // enabledMcpjsonServers, so the summary names all three surfaces.
            return "Hard sub-agent allowlist + hooks + project MCP approval";
        }

        if (std.mem.eql(u8, self.id, "gemini")) {
            return "Medium hooks + sub-agent tool scoping";
        }

        if (caps.specialists.code_query == .config and
            caps.specialists.debug == .config and
            caps.specialists.memory == .config)
        {
            return "Hard sub-agent allowlist";
        }

        if (caps.specialists.code_query == .config or
            caps.specialists.debug == .config or
            caps.specialists.memory == .config)
        {
            if (std.mem.eql(u8, self.id, "amp")) {
                return "Medium permission bootstrap + skills + plugin";
            }
            return "Medium sub-agent tool scoping";
        }

        return "Soft prompt guidance";
    }

    /// Registry-derived description of where this host's specialist surface
    /// lives — the README support-matrix "Specialist Surface" column.
    pub fn specialistSurfaceSummary(self: *const Agent, allocator: std.mem.Allocator) ![]u8 {
        const caps = self.capabilities();
        const path = self.agent_file_path orelse return try allocator.dupe(u8, "");

        if (caps.subagent_support == .shared_config) {
            if (self.mcp_format == .toml) {
                return try allocator.dupe(u8, "`[agents.*]` TOML sections");
            }
            return try std.fmt.allocPrint(allocator, "`{s}` custom modes", .{path});
        }

        // Dedicated files and skills live under a per-host directory; skill
        // layouts add a per-specialist folder that is stripped so the summary
        // names the shared root.
        const basename_start = (std.mem.lastIndexOfScalar(u8, path, '/') orelse return try allocator.dupe(u8, "")) + 1;
        var dir = path[0..basename_start];
        if (std.mem.lastIndexOfScalar(u8, dir[0 .. dir.len - 1], '/')) |parent_end| {
            if (std.mem.startsWith(u8, dir[parent_end + 1 ..], "cog-")) {
                dir = path[0 .. parent_end + 1];
            }
        }
        return try std.fmt.allocPrint(allocator, "`{s}`", .{dir});
    }

    /// One README support-matrix row, byte-for-byte in the committed format.
    pub fn supportMatrixRow(self: *const Agent, allocator: std.mem.Allocator) ![]u8 {
        const surface = try self.specialistSurfaceSummary(allocator);
        defer allocator.free(surface);

        const mcp_cell = if (self.mcp_format == .global_only)
            try allocator.dupe(u8, "Global config")
        else
            try std.fmt.allocPrint(allocator, "`{s}`", .{self.mcp_path.?});
        defer allocator.free(mcp_cell);

        var row: std.ArrayListUnmanaged(u8) = .empty;
        errdefer row.deinit(allocator);

        const cells = [_][]const u8{
            self.display_name,
            mcp_cell,
            surface,
            self.toolPermissionsSummary(),
            self.overrideSummary(),
            self.contextPackagingSummary(),
            self.memoryEnrichmentSummary(),
        };
        for (cells) |cell| {
            try row.appendSlice(allocator, "| ");
            if (cell.len != 0) {
                try row.appendSlice(allocator, cell);
                try row.append(allocator, ' ');
            }
        }
        try row.append(allocator, '|');
        return try row.toOwnedSlice(allocator);
    }
};

pub const support_matrix_header =
    "| Agent | MCP Config | Specialist Surface | Tool Permissions | Cog-First Override | Context Packaging | Memory Write Enrichment |\n" ++
    "|-------|------------|--------------------|------------------|--------------------|------------------|-------------------------|";

/// Render the complete support matrix from the registry, sorted by display
/// name, exactly as committed in README.md. A test compares this output with
/// the README table so registry/docs drift fails the build.
pub fn renderSupportMatrix(allocator: std.mem.Allocator) ![]u8 {
    debug_log.log("agents.renderSupportMatrix: rendering {d} hosts", .{agents.len});

    var sorted: [agents.len]usize = undefined;
    for (0..agents.len) |i| sorted[i] = i;
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        const current = sorted[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, agents[current].display_name, agents[sorted[j - 1]].display_name) == .lt) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = current;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, support_matrix_header);
    for (sorted) |agent_index| {
        const row = try agents[agent_index].supportMatrixRow(allocator);
        defer allocator.free(row);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, row);
    }
    return try out.toOwnedSlice(allocator);
}

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
        \\  - mcp__cog__code_explore
        \\  - mcp__cog__code_query
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
        \\description: Memory sub-agent for recall-first triage, escalation, and consolidation
        \\tools:
        \\  - mcp__cog__mem_recall
        \\  - mcp__cog__code_explore
        \\  - mcp__cog__code_query
        \\  - mcp__cog__mem_trace
        \\  - mcp__cog__mem_connections
        \\  - mcp__cog__mem_get
        \\  - mcp__cog__mem_learn
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
        \\  - mcp__cog__mem_associate
        \\  - mcp__cog__mem_refactor
        \\  - mcp__cog__mem_update
        \\  - mcp__cog__mem_deprecate
        \\  - Read
        \\mcpServers:
        \\  - cog
        \\---
        \\
        ,
        .validate_file_path = ".claude/agents/cog-mem-validate.md",
        .validate_file_header =
        \\---
        \\name: cog-mem-validate
        \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        \\tools:
        \\  - mcp__cog__mem_learn
        \\  - mcp__cog__mem_associate
        \\  - mcp__cog__mem_refactor
        \\  - mcp__cog__mem_update
        \\  - mcp__cog__mem_deprecate
        \\  - mcp__cog__mem_list_short_term
        \\  - mcp__cog__mem_reinforce
        \\  - mcp__cog__mem_flush
        \\  - mcp__cog__mem_verify
        \\mcpServers:
        \\  - cog
        \\---
        \\
        ,
        .observe_file_path = ".claude/agents/cog-observe.md",
        .observe_file_header =
        \\---
        \\name: cog-observe
        \\description: System observability sub-agent that investigates syscalls, GPU, network, and cost via cog observe tools
        \\tools:
        \\  - mcp__cog__observe_start
        \\  - mcp__cog__observe_stop
        \\  - mcp__cog__observe_events
        \\  - mcp__cog__observe_causal_chains
        \\  - mcp__cog__observe_query
        \\  - mcp__cog__observe_sessions
        \\  - mcp__cog__observe_status
        \\  - mcp__cog__code_explore
        \\  - mcp__cog__code_query
        \\  - mcp__cog__mem_recall
        \\  - Read
        \\  - Bash
        \\mcpServers:
        \\  - cog
        \\maxTurns: 15
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
        .agent_file_header = (
            \\---
            \\name: cog-code-query
            \\description: Explore code structure using the Cog SCIP index
        ++ gemini_code_query_tools ++
            \\---
            \\
        ),
        .debug_file_path = ".gemini/agents/cog-debug.md",
        .debug_file_header = (
            \\---
            \\name: cog-debug
            \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        ++ gemini_debug_tools ++
            \\max_turns: 15
            \\---
            \\
        ),
        .mem_file_path = ".gemini/agents/cog-mem.md",
        .mem_file_header = (
            \\---
            \\name: cog-mem
            \\description: Memory sub-agent for recall, consolidation, and maintenance
        ++ gemini_memory_tools ++
            \\---
            \\
        ),
        .validate_file_path = ".gemini/agents/cog-mem-validate.md",
        .validate_file_header = (
            \\---
            \\name: cog-mem-validate
            \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        ++ gemini_validate_tools ++
            \\---
            \\
        ),
        .observe_file_path = ".gemini/agents/cog-observe.md",
        .observe_file_header = (
            \\---
            \\name: cog-observe
            \\description: System observability sub-agent that investigates syscalls, GPU, network, and cost via cog observe tools
        ++ gemini_observe_tools ++
            \\max_turns: 15
            \\---
            \\
        ),
    },
    // ── GitHub Copilot ──────────────────────────────────────────────
    .{
        .id = "copilot",
        .display_name = "GitHub Copilot",
        .prompt_target = .copilot_instructions,
        .mcp_path = ".vscode/mcp.json",
        .mcp_format = .json_servers,
        .agent_file_path = ".github/agents/cog-code-query.agent.md",
        .agent_file_header = (
            \\---
            \\name: cog-code-query
            \\description: Explore code structure using the Cog SCIP index
        ++ copilot_code_query_tools ++
            \\---
            \\
        ),
        .debug_file_path = ".github/agents/cog-debug.agent.md",
        .debug_file_header = (
            \\---
            \\name: cog-debug
            \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        ++ copilot_debug_tools ++
            \\user-invokable: false
            \\---
            \\
        ),
        .mem_file_path = ".github/agents/cog-mem.agent.md",
        .mem_file_header = (
            \\---
            \\name: cog-mem
            \\description: Memory sub-agent for recall, consolidation, and maintenance
        ++ copilot_memory_tools ++
            \\user-invokable: false
            \\---
            \\
        ),
        .validate_file_path = ".github/agents/cog-mem-validate.agent.md",
        .validate_file_header = (
            \\---
            \\name: cog-mem-validate
            \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        ++ copilot_validate_tools ++
            \\user-invokable: false
            \\---
            \\
        ),
        .observe_file_path = ".github/agents/cog-observe.agent.md",
        .observe_file_header = (
            \\---
            \\name: cog-observe
            \\description: System observability sub-agent that investigates syscalls, GPU, network, and cost via cog observe tools
        ++ copilot_observe_tools ++
            \\user-invokable: false
            \\---
            \\
        ),
    },
    // ── Windsurf ────────────────────────────────────────────────────
    .{
        .id = "windsurf",
        .display_name = "Windsurf",
        .prompt_target = .agents_md,
        .mcp_path = null,
        .mcp_format = .global_only,
        .agent_file_path = ".windsurf/skills/cog-code-query/SKILL.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
        .debug_file_path = ".windsurf/skills/cog-debug/SKILL.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".windsurf/skills/cog-mem/SKILL.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
        .validate_file_path = ".windsurf/skills/cog-mem-validate/SKILL.md",
        .validate_file_header =
        \\---
        \\name: cog-mem-validate
        \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        \\---
        \\
        ,
        .observe_file_path = ".windsurf/skills/cog-observe/SKILL.md",
        .observe_file_header =
        \\---
        \\name: cog-observe
        \\description: System observability specialist for syscall, GPU, network, and cost investigation
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
        .agent_file_path = ".cursor/rules/cog-code-query.mdc",
        .agent_file_header =
        \\---
        \\description: Explore code structure using the Cog SCIP index
        \\globs:
        \\alwaysApply: false
        \\---
        \\
        ,
        .debug_file_path = ".cursor/rules/cog-debug.mdc",
        .debug_file_header =
        \\---
        \\description: Debug runtime behavior with Cog debugger tools
        \\globs:
        \\alwaysApply: false
        \\---
        \\
        ,
        .mem_file_path = ".cursor/rules/cog-mem.mdc",
        .mem_file_header =
        \\---
        \\description: Recall and maintain durable project memory with Cog
        \\globs:
        \\alwaysApply: false
        \\---
        \\
        ,
        .validate_file_path = ".cursor/rules/cog-mem-validate.mdc",
        .validate_file_header =
        \\---
        \\description: Validate and consolidate Cog memory after work
        \\globs:
        \\alwaysApply: false
        \\---
        \\
        ,
        .observe_file_path = ".cursor/rules/cog-observe.mdc",
        .observe_file_header =
        \\---
        \\description: Investigate system behavior with Cog observability tools
        \\globs:
        \\alwaysApply: false
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
        .validate_file_path = ".codex/config.toml",
        .validate_file_header = null,
        .observe_file_path = ".codex/config.toml",
        .observe_file_header = null,
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
        .validate_file_path = ".agents/skills/cog-mem-validate/SKILL.md",
        .validate_file_header =
        \\---
        \\name: cog-mem-validate
        \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        \\---
        \\
        ,
        .observe_file_path = ".agents/skills/cog-observe/SKILL.md",
        .observe_file_header =
        \\---
        \\name: cog-observe
        \\description: System observability specialist for syscall, GPU, network, and cost investigation
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
        .agent_file_path = ".goose/skills/cog-code-query/SKILL.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
        .debug_file_path = ".goose/skills/cog-debug/SKILL.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".goose/skills/cog-mem/SKILL.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
        .validate_file_path = ".goose/skills/cog-mem-validate/SKILL.md",
        .validate_file_header =
        \\---
        \\name: cog-mem-validate
        \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        \\---
        \\
        ,
        .observe_file_path = ".goose/skills/cog-observe/SKILL.md",
        .observe_file_header =
        \\---
        \\name: cog-observe
        \\description: System observability specialist for syscall, GPU, network, and cost investigation
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
        .validate_file_path = ".roomodes",
        .validate_file_header = null,
        .observe_file_path = ".roomodes",
        .observe_file_header = null,
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
        .validate_file_path = ".opencode/agents/cog-mem-validate.md",
        .validate_file_header =
        \\---
        \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
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
        .observe_file_path = ".opencode/agents/cog-observe.md",
        .observe_file_header =
        \\---
        \\description: System observability specialist for syscall, GPU, network, and cost investigation
        \\mode: subagent
        \\permission:
        \\  read: allow
        \\  glob: deny
        \\  grep: deny
        \\  list: deny
        \\  bash: allow
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
    // ── Pi ──────────────────────────────────────────────────────────
    .{
        .id = "pi",
        .display_name = "Pi",
        .prompt_target = .agents_md,
        .mcp_path = ".pi/mcp.json",
        .mcp_format = .json_pi,
        .agent_file_path = ".pi/skills/cog-code-query/SKILL.md",
        .agent_file_header =
        \\---
        \\name: cog-code-query
        \\description: Explore code structure using the Cog SCIP index
        \\---
        \\
        ,
        .debug_file_path = ".pi/skills/cog-debug/SKILL.md",
        .debug_file_header =
        \\---
        \\name: cog-debug
        \\description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
        \\---
        \\
        ,
        .mem_file_path = ".pi/skills/cog-mem/SKILL.md",
        .mem_file_header =
        \\---
        \\name: cog-mem
        \\description: Memory sub-agent for recall, consolidation, and maintenance
        \\---
        \\
        ,
        .validate_file_path = ".pi/skills/cog-mem-validate/SKILL.md",
        .validate_file_header =
        \\---
        \\name: cog-mem-validate
        \\description: Post-task memory validation — learns durable knowledge and consolidates short-term memories in one call
        \\---
        \\
        ,
        .observe_file_path = ".pi/skills/cog-observe/SKILL.md",
        .observe_file_header =
        \\---
        \\name: cog-observe
        \\description: System observability specialist for syscall, GPU, network, and cost investigation
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
    try std.testing.expectEqual(@as(usize, 11), agents.len);
}

test "buildMenuEntries sorts alphabetically by default" {
    var counts = agent_usage.Counts.init(std.testing.allocator);
    defer counts.deinit();
    const entries = buildMenuEntriesFromCounts(&counts);
    try std.testing.expectEqualStrings("Amp", entries[0].item.label);
    try std.testing.expectEqualStrings("Windsurf", entries[10].item.label);
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
    try std.testing.expect(!agents[10].supportsToolPermissions()); // pi
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
    try std.testing.expect(agents[10].overrideEnforcementLevel() == .medium); // pi
}

test "capability model matches mcp strategy" {
    for (agents) |agent| {
        const caps = agent.capabilities();
        try std.testing.expectEqual(agent.mcp_path != null, caps.repo_local_mcp);
    }
}

test "capability model keeps subagent topology explicit" {
    try std.testing.expect(agents[3].capabilities().subagent_support == .workflow_files); // windsurf
    try std.testing.expect(agents[4].capabilities().subagent_support == .workflow_files); // cursor
    try std.testing.expect(agents[5].capabilities().subagent_support == .shared_config); // codex
    try std.testing.expect(agents[7].capabilities().subagent_support == .workflow_files); // goose
    try std.testing.expect(agents[8].capabilities().subagent_support == .shared_config); // roo
    try std.testing.expect(agents[9].capabilities().subagent_support == .dedicated_files); // opencode
    try std.testing.expect(agents[10].capabilities().subagent_support == .workflow_files); // pi
    try std.testing.expectEqualStrings(".windsurf/skills/cog-code-query/SKILL.md", agents[3].agent_file_path.?); // windsurf
    try std.testing.expectEqualStrings(".cursor/rules/cog-code-query.mdc", agents[4].agent_file_path.?); // cursor
    try std.testing.expectEqualStrings(".agents/skills/cog-code-query/SKILL.md", agents[6].agent_file_path.?); // amp
    try std.testing.expectEqualStrings(".agents/skills/cog-debug/SKILL.md", agents[6].debug_file_path.?); // amp
    try std.testing.expectEqualStrings(".agents/skills/cog-mem/SKILL.md", agents[6].mem_file_path.?); // amp
    try std.testing.expectEqualStrings(".goose/skills/cog-code-query/SKILL.md", agents[7].agent_file_path.?); // goose
    try std.testing.expectEqualStrings(".pi/skills/cog-code-query/SKILL.md", agents[10].agent_file_path.?); // pi
    try std.testing.expectEqualStrings(".pi/skills/cog-debug/SKILL.md", agents[10].debug_file_path.?); // pi
    try std.testing.expectEqualStrings(".pi/skills/cog-mem/SKILL.md", agents[10].mem_file_path.?); // pi

    for (agents) |agent| {
        const caps = agent.capabilities();
        if (caps.subagent_support == .dedicated_files or caps.subagent_support == .workflow_files) {
            try std.testing.expect(caps.dedicated_subagent_files);
        } else {
            try std.testing.expect(!caps.dedicated_subagent_files);
        }
    }
}

test "runtime policy plugins stay explicitly modeled" {
    var runtime_plugin_agents: usize = 0;
    for (agents) |agent| {
        if (agent.capabilities().runtime_policy_plugins) {
            runtime_plugin_agents += 1;
            try std.testing.expect(std.mem.eql(u8, agent.id, "amp") or std.mem.eql(u8, agent.id, "opencode") or std.mem.eql(u8, agent.id, "pi"));
        }
    }

    try std.testing.expectEqual(@as(usize, 3), runtime_plugin_agents);
}

test "tool permission support stays capability-driven" {
    for (agents) |agent| {
        try std.testing.expectEqual(agent.capabilities().auto_tool_permissions, agent.supportsToolPermissions());
    }
}

test "enforcement level stays capability-driven" {
    try std.testing.expect(agents[0].capabilities().specialists.code_query == .config);
    try std.testing.expect(agents[0].capabilities().specialists.debug == .config);
    try std.testing.expect(agents[0].capabilities().specialists.memory == .config);

    try std.testing.expect(agents[9].capabilities().specialists.code_query == .runtime);
    try std.testing.expect(agents[9].capabilities().specialists.debug == .runtime);
    try std.testing.expect(agents[9].capabilities().specialists.memory == .runtime);

    try std.testing.expect(agents[2].capabilities().specialists.code_query == .prompt_only);
    try std.testing.expect(agents[2].capabilities().specialists.debug == .prompt_only);
    try std.testing.expect(agents[2].capabilities().specialists.memory == .prompt_only);

    try std.testing.expect(agents[0].capabilities().memory_write_enrichment == .config);
    try std.testing.expect(agents[6].capabilities().memory_write_enrichment == .runtime);
    try std.testing.expect(agents[9].capabilities().memory_write_enrichment == .runtime);
    try std.testing.expect(agents[2].capabilities().memory_write_enrichment == .prompt_only);

    try std.testing.expect(agents[6].capabilities().specialists.code_query == .runtime);
    try std.testing.expect(agents[6].capabilities().specialists.memory == .runtime);

    try std.testing.expect(agents[10].capabilities().specialists.code_query == .runtime);
    try std.testing.expect(agents[10].capabilities().specialists.debug == .prompt_only);
    try std.testing.expect(agents[10].capabilities().specialists.memory == .runtime);
    try std.testing.expect(agents[10].capabilities().memory_write_enrichment == .runtime);

    for (agents) |agent| {
        try std.testing.expect(agent.capabilities().context_packaging);
    }
}

test "code-query headers prefer cog-first exploration" {
    const claude_header = agents[0].agent_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "Glob") == null);
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "Grep") == null);
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "mcp__cog__code_explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_header, "mcp__cog__code_query") != null);

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

test "claude memory header supports recall-first escalation" {
    const claude_mem_header = agents[0].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, claude_mem_header, "mcp__cog__mem_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_mem_header, "mcp__cog__code_explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_mem_header, "mcp__cog__mem_learn") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_mem_header, "mcp__cog__mem_reinforce") != null);
}

test "opencode debug header stays debugger-focused" {
    const opencode_debug_header = agents[9].debug_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "read: allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "glob: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "bash: deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, opencode_debug_header, "cog_*: allow") != null);
}

test "cursor exposes project rule equivalents for every specialist" {
    try std.testing.expectEqualStrings(".cursor/rules/cog-code-query.mdc", agents[4].agent_file_path.?);
    try std.testing.expectEqualStrings(".cursor/rules/cog-debug.mdc", agents[4].debug_file_path.?);
    try std.testing.expectEqualStrings(".cursor/rules/cog-mem.mdc", agents[4].mem_file_path.?);
    try std.testing.expectEqualStrings(".cursor/rules/cog-mem-validate.mdc", agents[4].validate_file_path.?);
    try std.testing.expectEqualStrings(".cursor/rules/cog-observe.mdc", agents[4].observe_file_path.?);
}

test "specialist capabilities derive asset coverage across the full registry" {
    inline for (std.meta.tags(SpecialistKind)) |kind| {
        for (agents) |agent| {
            const supported = agent.capabilities().specialists.supports(kind);
            try std.testing.expectEqual(supported, agent.specialistPath(kind) != null);
            try std.testing.expect(supported);
        }
    }
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
    try std.testing.expect(std.mem.indexOf(u8, gemini_debug_header, "cog__mem_recall") != null);

    const gemini_mem_header = agents[1].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, gemini_mem_header, "cog__mem_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_mem_header, "cog__code_explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_mem_header, "cog__mem_learn") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_mem_header, "cog__mem_associate") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, copilot_debug_header, "cog/mem_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_debug_header, "cog/*") == null);

    const copilot_mem_header = agents[2].mem_file_header orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, copilot_mem_header, "cog/mem_recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_mem_header, "cog/code_explore") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_mem_header, "cog/mem_learn") != null);
    try std.testing.expect(std.mem.indexOf(u8, copilot_mem_header, "cog/mem_associate") != null);
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

    try std.testing.expectEqual(@as(usize, 9), local_count);
    try std.testing.expectEqual(@as(usize, 2), global_only_count);
}

test "support summaries stay capability-driven" {
    try std.testing.expectEqualStrings("Auto-allow", agents[0].toolPermissionsSummary());
    try std.testing.expectEqualStrings("", agents[2].toolPermissionsSummary());

    try std.testing.expectEqualStrings("Hard sub-agent allowlist + hooks + project MCP approval", agents[0].overrideSummary());
    try std.testing.expectEqualStrings("Medium hooks + sub-agent tool scoping", agents[1].overrideSummary());
    try std.testing.expectEqualStrings("Soft specialist tool scoping", agents[2].overrideSummary());
    try std.testing.expectEqualStrings("Soft skills + rules", agents[3].overrideSummary());
    try std.testing.expectEqualStrings("Soft AGENTS.md + project rules", agents[4].overrideSummary());
    try std.testing.expectEqualStrings("Soft shared-config specialist guidance", agents[5].overrideSummary());
    try std.testing.expectEqualStrings("Medium runtime plugins + sub-agent permissions", agents[6].overrideSummary());
    try std.testing.expectEqualStrings("Soft skill guidance", agents[7].overrideSummary());
    try std.testing.expectEqualStrings("Medium native mode groups", agents[8].overrideSummary());
    try std.testing.expectEqualStrings("Medium runtime plugins + sub-agent permissions", agents[9].overrideSummary());
    try std.testing.expectEqualStrings("Medium extension hooks + skills", agents[10].overrideSummary());
}

test "support matrix helpers stay aligned" {
    try std.testing.expectEqualStrings(".mcp.json", agents[0].mcpConfigSummary());
    try std.testing.expectEqualStrings("Global config", agents[3].mcpConfigSummary());
    try std.testing.expectEqualStrings("Yes", agents[4].subAgentsSummary());
    try std.testing.expectEqualStrings("Yes", agents[9].subAgentsSummary());
    try std.testing.expectEqualStrings("Yes", agents[0].contextPackagingSummary());
    try std.testing.expectEqualStrings("Runtime reminders", agents[6].memoryEnrichmentSummary());
    try std.testing.expectEqualStrings("Runtime reminders", agents[9].memoryEnrichmentSummary());

    const opencode_row = try agents[9].supportMatrixRow(std.testing.allocator);
    defer std.testing.allocator.free(opencode_row);
    try std.testing.expectEqualStrings(
        "| OpenCode | `opencode.json` | `.opencode/agents/` | Auto-allow | Medium runtime plugins + sub-agent permissions | Yes | Runtime reminders |",
        opencode_row,
    );

    const goose_row = try agents[7].supportMatrixRow(std.testing.allocator);
    defer std.testing.allocator.free(goose_row);
    try std.testing.expectEqualStrings(
        "| Goose | Global config | `.goose/skills/` | | Soft skill guidance | Yes | Prompt guidance |",
        goose_row,
    );
}

test "specialist surface summaries derive from registry paths" {
    const allocator = std.testing.allocator;

    const claude = try agents[0].specialistSurfaceSummary(allocator);
    defer allocator.free(claude);
    try std.testing.expectEqualStrings("`.claude/agents/`", claude);

    const amp = try agents[6].specialistSurfaceSummary(allocator);
    defer allocator.free(amp);
    try std.testing.expectEqualStrings("`.agents/skills/`", amp);

    const codex = try agents[5].specialistSurfaceSummary(allocator);
    defer allocator.free(codex);
    try std.testing.expectEqualStrings("`[agents.*]` TOML sections", codex);

    const roo = try agents[8].specialistSurfaceSummary(allocator);
    defer allocator.free(roo);
    try std.testing.expectEqualStrings("`.roomodes` custom modes", roo);
}

test "renderSupportMatrix lists every registry host alphabetically" {
    const allocator = std.testing.allocator;
    const matrix = try renderSupportMatrix(allocator);
    defer allocator.free(matrix);

    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, matrix, '\n');
    while (lines.next()) |_| line_count += 1;
    try std.testing.expectEqual(agents.len + 2, line_count);

    for (agents) |agent| {
        try std.testing.expect(std.mem.indexOf(u8, matrix, agent.display_name) != null);
    }

    const amp_pos = std.mem.indexOf(u8, matrix, "| Amp |") orelse return error.TestUnexpectedResult;
    const windsurf_pos = std.mem.indexOf(u8, matrix, "| Windsurf |") orelse return error.TestUnexpectedResult;
    try std.testing.expect(amp_pos < windsurf_pos);
}

test "observe specialist files are hidden while feature is disabled" {
    for (agents) |agent| {
        try std.testing.expect(agent.observeFilePath(false) == null);
        try std.testing.expect(agent.observeFileHeader(false) == null);
    }
}

test "observe specialist files preserve all-host parity when enabled" {
    var supported: usize = 0;
    for (agents) |agent| {
        if (agent.observeFilePath(true) != null) supported += 1;
    }
    try std.testing.expectEqual(agents.len, supported);
}

/// A marker that only appears in tool lists belonging to this specialist's
/// own tool family. Used to derive "never reference an unsupported
/// specialist's tools" checks from the registry instead of per-host tests.
fn specialistToolMarker(kind: SpecialistKind) []const u8 {
    return switch (kind) {
        .code_query => "code_query",
        .debug => "debug_launch",
        .memory => "mem_learn",
        .validate => "mem_reinforce",
        .observe => "observe_start",
    };
}

/// True when a header scopes individual Cog tools by name (Claude/Gemini
/// `cog__` style or Copilot `cog/` style) rather than wildcard permissions.
fn headerScopesCogToolsExplicitly(header: []const u8) bool {
    return std.mem.indexOf(u8, header, "cog__") != null or
        std.mem.indexOf(u8, header, "cog/") != null;
}

test "registry assets match declared capabilities for every host" {
    for (agents) |agent| {
        const caps = agent.capabilities();

        // MCP install assets must follow the repo-local MCP capability.
        try std.testing.expectEqual(caps.repo_local_mcp, agent.mcp_path != null);
        try std.testing.expectEqual(caps.repo_local_mcp, agent.mcp_format != .global_only);

        inline for (std.meta.tags(SpecialistKind)) |kind| {
            const supported = caps.specialists.supports(kind);
            try std.testing.expectEqual(supported, agent.specialistPath(kind) != null);

            if (caps.subagent_support == .shared_config) {
                // Shared-config hosts synthesize specialist sections inside
                // one host config file; they never carry per-file headers.
                try std.testing.expect(agent.specialistHeader(kind) == null);
            } else {
                try std.testing.expectEqual(supported, agent.specialistHeader(kind) != null);
            }
        }
    }
}

test "hosts never receive instruction files referencing unsupported specialists" {
    inline for (std.meta.tags(SpecialistKind)) |kind| {
        for (agents) |agent| {
            const caps = agent.capabilities();
            if (caps.specialists.supports(kind)) continue;

            // An unsupported specialist must not install any asset...
            try std.testing.expect(agent.specialistPath(kind) == null);
            try std.testing.expect(agent.specialistHeader(kind) == null);

            // ...and no other instruction header for this host may reference
            // that specialist's tool family (e.g. no debug delegation when
            // debug tools are absent).
            inline for (std.meta.tags(SpecialistKind)) |other| {
                if (agent.specialistHeader(other)) |header| {
                    try std.testing.expect(std.mem.indexOf(u8, header, specialistToolMarker(kind)) == null);
                }
            }
        }
    }
}

test "explicit tool scoping always covers the specialist's own tool family" {
    inline for (std.meta.tags(SpecialistKind)) |kind| {
        for (agents) |agent| {
            const header = agent.specialistHeader(kind) orelse continue;
            if (!headerScopesCogToolsExplicitly(header)) continue;
            try std.testing.expect(std.mem.indexOf(u8, header, specialistToolMarker(kind)) != null);
        }
    }
}

test "specialist availability derives from capabilities and memory gating" {
    for (agents) |agent| {
        const specialists = agent.capabilities().specialists;
        const with_memory = specialists.availability(true);
        const without_memory = specialists.availability(false);

        inline for (std.meta.tags(SpecialistKind)) |kind| {
            try std.testing.expectEqual(specialists.supports(kind), with_memory.has(kind));
        }

        // Disabling memory must always strip memory-backed specialists while
        // leaving the rest of the host's declared surface intact.
        try std.testing.expect(!without_memory.memory);
        try std.testing.expect(!without_memory.validate);
        try std.testing.expectEqual(specialists.supports(.code_query), without_memory.code_query);
        try std.testing.expectEqual(specialists.supports(.debug), without_memory.debug);
        try std.testing.expectEqual(specialists.supports(.observe), without_memory.observe);
    }
}

test "hosts that advertise specialist files have debug_file_path" {
    for (agents) |agent| {
        if (agent.subAgentsSummary().len != 0) {
            try std.testing.expect(agent.debug_file_path != null);
        }
    }
}

test "hosts that advertise specialist files have mem_file_path" {
    for (agents) |agent| {
        if (agent.subAgentsSummary().len != 0) {
            try std.testing.expect(agent.mem_file_path != null);
        }
    }
}
