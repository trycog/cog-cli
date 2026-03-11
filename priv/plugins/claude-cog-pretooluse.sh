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

case "$tool_name" in
  Grep|Glob)
    deny "Use Cog code intelligence tools before raw file search when the Cog MCP server is configured."
    ;;
  Bash)
    if printf '%s' "$payload" | grep -Eq '"command"[[:space:]]*:[[:space:]]*"[^"]*(rg|grep|find)[^"]*"'; then
      deny "Use Cog code intelligence tools before raw shell search commands when the Cog MCP server is configured."
    fi
    ;;
esac

exit 0
