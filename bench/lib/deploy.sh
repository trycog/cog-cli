#!/usr/bin/env bash
# Shared deployment library for all benchmark suites.
# Deploys canonical PROMPT.md and sub-agent files from priv/.
#
# Usage:
#   source bench/lib/deploy.sh
#   deploy_canonical "$workspace_dir"

# Resolve paths relative to the repo root
# Support both bash (BASH_SOURCE) and zsh (${(%):-%x})
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _DEPLOY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _DEPLOY_LIB_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
fi
_REPO_ROOT="$(cd "$_DEPLOY_LIB_DIR/../.." && pwd)"
_PROMPT_MD="$_REPO_ROOT/priv/prompts/PROMPT.md"
_AGENTS_DIR="$_REPO_ROOT/priv/agents"

# ── deploy_claude_md <dir> ────────────────────────────────────────────────
# Reads priv/prompts/PROMPT.md, wraps in <cog>...</cog> tags, writes CLAUDE.md
deploy_claude_md() {
  local dir="$1"
  local prompt
  prompt=$(<"$_PROMPT_MD")

  cat > "$dir/CLAUDE.md" << CLAUDEEOF
<cog>
$prompt
</cog>
CLAUDEEOF
}

# ── deploy_agents <dir> ───────────────────────────────────────────────────
# Copies all 3 agent bodies from priv/agents/ into $dir/.claude/agents/
# with Claude Code YAML frontmatter headers.
deploy_agents() {
  local dir="$1"
  mkdir -p "$dir/.claude/agents"

  # cog-code-query agent
  cat > "$dir/.claude/agents/cog-code-query.md" << 'AGENTEOF'
---
name: cog-code-query
description: Explore code structure using the Cog SCIP index
tools:
  - Read
  - Glob
  - Grep
mcpServers:
  - cog
model: haiku
---

AGENTEOF
  cat "$_AGENTS_DIR/cog-code-query.md" >> "$dir/.claude/agents/cog-code-query.md"

  # cog-debug agent
  cat > "$dir/.claude/agents/cog-debug.md" << 'AGENTEOF'
---
name: cog-debug
description: Debug subagent that investigates runtime behavior via cog debugger, code, and memory tools
tools:
  - mcp__cog__cog_debug_launch
  - mcp__cog__cog_debug_breakpoint
  - mcp__cog__cog_debug_run
  - mcp__cog__cog_debug_inspect
  - mcp__cog__cog_debug_stacktrace
  - mcp__cog__cog_debug_stop
  - mcp__cog__cog_debug_threads
  - mcp__cog__cog_debug_scopes
  - mcp__cog__cog_debug_set_variable
  - mcp__cog__cog_debug_watchpoint
  - mcp__cog__cog_debug_exception_info
  - mcp__cog__cog_debug_attach
  - mcp__cog__cog_debug_restart
  - mcp__cog__cog_debug_sessions
  - mcp__cog__cog_debug_poll_events
  - mcp__cog__cog_code_query
  - mcp__cog__cog_code_explore
  - mcp__cog__cog_code_status
  - mcp__cog__cog_mem_recall
  - mcp__cog__cog_mem_bulk_recall
  - Read
  - Bash
mcpServers:
  - cog
maxTurns: 15
---

AGENTEOF
  cat "$_AGENTS_DIR/cog-debug.md" >> "$dir/.claude/agents/cog-debug.md"

  # cog-mem agent
  cat > "$dir/.claude/agents/cog-mem.md" << 'AGENTEOF'
---
name: cog-mem
description: Memory sub-agent for recall, consolidation, and maintenance
tools:
  - mcp__cog__cog_mem_recall
  - mcp__cog__cog_mem_bulk_recall
  - mcp__cog__cog_mem_trace
  - mcp__cog__cog_mem_connections
  - mcp__cog__cog_mem_get
  - mcp__cog__cog_mem_list_short_term
  - mcp__cog__cog_mem_reinforce
  - mcp__cog__cog_mem_flush
  - mcp__cog__cog_mem_stale
  - mcp__cog__cog_mem_verify
  - mcp__cog__cog_mem_stats
  - mcp__cog__cog_mem_orphans
  - mcp__cog__cog_mem_connectivity
  - mcp__cog__cog_mem_list_terms
  - mcp__cog__cog_mem_unlink
  - mcp__cog__cog_mem_meld
  - mcp__cog__cog_mem_bulk_learn
  - mcp__cog__cog_mem_bulk_associate
mcpServers:
  - cog
---

AGENTEOF
  cat "$_AGENTS_DIR/cog-mem.md" >> "$dir/.claude/agents/cog-mem.md"
}

# ── deploy_canonical <dir> ────────────────────────────────────────────────
# Deploys both CLAUDE.md and all 3 agents.
deploy_canonical() {
  local dir="$1"
  deploy_claude_md "$dir"
  deploy_agents "$dir"
}
