#!/bin/sh
set -eu

payload=$(cat)

if [ ! -f ".gemini/settings.json" ] || ! grep -q '"cog"' ".gemini/settings.json"; then
  exit 0
fi

tool_name=$(printf '%s' "$payload" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

case "$tool_name" in
  grep|glob|search_file_content)
    printf '%s\n' "Cog policy: use Cog code intelligence tools before raw file search when the Cog MCP server is configured." >&2
    exit 2
    ;;
  run_shell_command)
    if printf '%s' "$payload" | grep -Eq '"command"[[:space:]]*:[[:space:]]*"[^"]*\b(rg|grep|find)\b[^"]*"'; then
      printf '%s\n' "Cog policy: use Cog code intelligence tools before shell search commands like grep, rg, find, or git grep when the Cog MCP server is configured." >&2
      exit 2
    fi
    ;;
  cog_mem_*|mcp__cog__mem_*)
    if printf '%s' "$payload" | grep -Eq '"relation"[[:space:]]*:[[:space:]]*"related_to"'; then
      printf '%s\n' "Cog memory quality: prefer a stronger predicate than related_to when a structural relationship exists." >&2
    fi
    if printf '%s' "$payload" | grep -Eq '"definition"[[:space:]]*:[[:space:]]*"[^"]{0,31}"'; then
      printf '%s\n' "Cog memory quality: include rationale or constraints when storing durable memory, not only a short label." >&2
    fi
    ;;
esac

exit 0
