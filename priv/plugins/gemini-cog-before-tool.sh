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
    if printf '%s' "$payload" | grep -Eq '"command"[[:space:]]*:[[:space:]]*"[^"]*(rg|grep|find)[^"]*"'; then
      printf '%s\n' "Cog policy: use Cog code intelligence tools before raw shell search commands when the Cog MCP server is configured." >&2
      exit 2
    fi
    ;;
esac

exit 0
