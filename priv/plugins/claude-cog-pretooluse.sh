#!/bin/sh
set -eu

payload=$(cat)

if [ ! -f ".mcp.json" ] || ! grep -q '"cog"' ".mcp.json"; then
  exit 0
fi

tool_name=$(printf '%s' "$payload" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

deny() {
  reason=$1
  printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"$reason\"}}"
  exit 0
}

advise() {
  printf '%s\n' "$1" >&2
}

case "$tool_name" in
  Grep|Glob)
    deny "Use Cog code intelligence tools before raw file search when the Cog MCP server is configured."
    ;;
  Bash)
    if printf '%s' "$payload" | grep -Eq '"command"[[:space:]]*:[[:space:]]*"[^"]*(rg|grep|find)[^"]*"'; then
      deny "Use Cog code intelligence tools before shell search commands like grep, rg, find, or git grep when the Cog MCP server is configured."
    fi
    ;;
  mcp__cog__mem_*|cog_mem_*)
    if printf '%s' "$payload" | grep -Eq '"relation"[[:space:]]*:[[:space:]]*"related_to"'; then
      advise "Cog memory quality: prefer a stronger predicate than related_to when the relationship is directional or structural."
    fi
    if printf '%s' "$payload" | grep -Eq '"definition"[[:space:]]*:[[:space:]]*"[^"]{0,31}"'; then
      advise "Cog memory quality: this definition looks short. Include why the fact matters, not just the surface description."
    fi
    ;;
esac

exit 0
