#!/usr/bin/env bash
# Setup script for SWE-bench Pro benchmarks (SWE-agent based)
#
# SWE-agent handles Docker containers, source extraction, and environment setup
# via SWE-ReX. This script just ensures dependencies are in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASKS_JSON="$SCRIPT_DIR/tasks.json"
COG_BIN="$ROOT_DIR/zig-out/bin/cog"

echo "═══════════════════════════════════════"
echo "  SWE-bench Pro Benchmark Setup"
echo "  (SWE-agent scaffold)"
echo "═══════════════════════════════════════"
echo ""

# ── Initialize SWE-agent submodule ──────────────────────────────────────

echo "Checking SWE-agent submodule..."
if [[ ! -f "$SCRIPT_DIR/SWE-agent/pyproject.toml" ]]; then
  echo "  Initializing submodule..."
  git -C "$ROOT_DIR" submodule update --init --recursive bench/swebench/SWE-agent
fi
echo "  SWE-agent: $(git -C "$SCRIPT_DIR/SWE-agent" log --oneline -1)"

# ── Install SWE-agent ──────────────────────────────────────────────────

echo ""
echo "Installing SWE-agent..."
pip install -e "$SCRIPT_DIR/SWE-agent" --quiet 2>&1 | tail -1 || true
if ! command -v sweagent &>/dev/null; then
  echo "  ERROR: sweagent CLI not found after install"
  echo "  Try: pip install -e bench/swebench/SWE-agent"
  exit 1
fi
echo "  sweagent: $(sweagent --version 2>&1 | head -1 || echo 'installed')"

# ── Check dependencies ─────────────────────────────────────────────────

echo ""
echo "Checking dependencies..."
missing=()

if ! command -v docker &>/dev/null; then
  missing+=("docker")
fi

if ! docker info &>/dev/null; then
  echo "  ERROR: Docker daemon is not running"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  missing+=("python3")
fi

if ! command -v claude &>/dev/null; then
  missing+=("claude (Claude Code CLI — needed for debugger-subagent)")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "  ERROR: Missing dependencies: ${missing[*]}"
  echo "  Install them and re-run setup.sh"
  exit 1
fi

echo "  docker:   $(docker --version 2>&1 | head -1)"
echo "  python3:  $(python3 --version 2>&1)"
echo "  sweagent: installed"
if command -v claude &>/dev/null; then
  echo "  claude:   $(claude --version 2>&1 | head -1)"
fi

# ── Build cog if needed ──────────────────────────────────────────────────

echo ""
if [[ -x "$COG_BIN" ]]; then
  echo "Cog binary found: $COG_BIN"
else
  echo "Building cog..."
  (cd "$ROOT_DIR" && zig build)
  if [[ ! -x "$COG_BIN" ]]; then
    echo "  ERROR: cog build failed, expected binary at $COG_BIN"
    exit 1
  fi
  echo "  Built: $COG_BIN"
fi

# ── Generate tasks ─────────────────────────────────────────────────────

echo ""
needs_generate=false
if [[ ! -f "$TASKS_JSON" ]]; then
  needs_generate=true
elif ! python3 -c "import json,sys; t=json.load(open('$TASKS_JSON')); sys.exit(0 if t and 'dockerhub_tag' in t[0] else 1)" 2>/dev/null; then
  echo "Detected stale tasks.json, regenerating..."
  needs_generate=true
fi

if $needs_generate; then
  echo "Generating tasks from SWE-bench Pro..."
  pip install --quiet datasets 2>/dev/null
  python3 "$SCRIPT_DIR/select_tasks_pro.py"
  echo ""
fi

task_count=$(python3 -c "import json; print(len(json.load(open('$TASKS_JSON'))))")
if [[ "$task_count" -eq 0 ]]; then
  echo "ERROR: tasks.json is empty."
  exit 1
fi
echo "Found $task_count tasks in tasks.json"

# Check SWE-agent JSONL
if [[ ! -f "$SCRIPT_DIR/tasks_sweagent.jsonl" ]]; then
  echo "Regenerating tasks_sweagent.jsonl..."
  python3 "$SCRIPT_DIR/select_tasks_pro.py"
fi
echo "SWE-agent instance file: tasks_sweagent.jsonl"

# ── Create output directories ──────────────────────────────────────────

mkdir -p "$SCRIPT_DIR/predictions"
mkdir -p "$SCRIPT_DIR/results"
mkdir -p "$SCRIPT_DIR/logs"

echo ""
echo "═══════════════════════════════════════"
echo "  Setup complete!"
echo "═══════════════════════════════════════"
echo ""
echo "Run benchmarks:"
echo "  bash bench/swebench/run.sh baseline 2      # baseline, first 2 tasks"
echo "  bash bench/swebench/run.sh debugger-subagent 2  # with cog_debug, first 2"
echo "  bash bench/swebench/run.sh all              # all tasks, all variants"
echo ""
echo "View results:"
echo "  bash bench/swebench/evaluate.sh"
echo "  bash bench/swebench/collect.sh"
echo "  open bench/swebench/dashboard.html"
