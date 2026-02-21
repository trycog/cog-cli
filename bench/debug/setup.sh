#!/usr/bin/env bash
# Setup script for cog debug benchmarks
# Verifies dependencies, compiles programs, configures Claude Code settings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR"
COG_BIN="${COG_BIN:-zig-out/bin/cog}"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Resolve cog binary
if [[ ! -f "$ROOT_DIR/$COG_BIN" ]]; then
  echo "Building cog binary..."
  (cd "$ROOT_DIR" && zig build)
fi
COG="$ROOT_DIR/$COG_BIN"

# Settings that auto-allow all tools needed for both benchmark variants
# Debug: mcp__cog__* (debugger tools), Read, Edit, Write, Bash, Grep, Glob, Task
# Traditional: Read, Edit, Write, Bash, Grep, Glob, Task (no cog_* tools)
SETTINGS_JSON='{"permissions":{"allow":["mcp__cog__*","Read(**)","Edit(**)","Grep(**)","Glob(**)","Write(**)","Task(**)","Bash(python3:*)","Bash(node:*)","Bash(make:*)","Bash(cargo:*)","Bash(bash:*)","Bash(cd:*)","Bash(./*)","Bash(timeout:*)"]}}'

echo "═══════════════════════════════════════"
echo "  Cog Debug Benchmark Setup"
echo "═══════════════════════════════════════"
echo ""

# Check dependencies
echo "Checking dependencies..."
missing=()

if ! command -v python3 &>/dev/null; then
  missing+=("python3")
fi

if ! command -v node &>/dev/null; then
  missing+=("node")
fi

if ! command -v g++ &>/dev/null; then
  # Try clang++ as fallback
  if ! command -v clang++ &>/dev/null; then
    missing+=("g++ or clang++")
  fi
fi

if ! command -v cargo &>/dev/null; then
  missing+=("cargo (Rust)")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "  ERROR: Missing dependencies: ${missing[*]}"
  echo "  Install them and re-run setup.sh"
  exit 1
fi

echo "  python3: $(python3 --version 2>&1)"
echo "  node:    $(node --version 2>&1)"
echo "  g++:     $(g++ --version 2>&1 | head -1)"
echo "  cargo:   $(cargo --version 2>&1)"
echo ""

configure_claude() {
  local dir="$1"

  # .mcp.json — MCP server config
  echo "{\"mcpServers\":{\"cog\":{\"command\":\"$COG\",\"args\":[\"mcp\"]}}}" > "$dir/.mcp.json"

  # .claude/settings.json — auto-allow all benchmark tools
  mkdir -p "$dir/.claude"
  echo "$SETTINGS_JSON" > "$dir/.claude/settings.json"
}

# Configure each language directory
for lang in python javascript cpp rust; do
  echo "Configuring $lang/..."
  configure_claude "$BENCH_DIR/$lang"
done

# Compile C++ programs
echo ""
echo "Compiling C++ programs..."
for test_dir in "$BENCH_DIR"/cpp/*/; do
  test_name=$(basename "$test_dir")
  if [[ -f "$test_dir/Makefile" ]]; then
    echo "  cpp/$test_name: compiling..."
    if make -C "$test_dir" -s 2>&1; then
      echo "  cpp/$test_name: OK"
    else
      echo "  cpp/$test_name: FAILED (will retry during benchmark)"
    fi
  fi
done

# Compile Rust programs
echo ""
echo "Compiling Rust programs..."
for test_dir in "$BENCH_DIR"/rust/*/; do
  test_name=$(basename "$test_dir")
  if [[ -f "$test_dir/Cargo.toml" ]]; then
    echo "  rust/$test_name: compiling..."
    if (cd "$test_dir" && cargo build 2>&1 | tail -1); then
      echo "  rust/$test_name: OK"
    else
      echo "  rust/$test_name: FAILED (will retry during benchmark)"
    fi
  fi
done

# Create .bench directory for results
mkdir -p "$BENCH_DIR/.bench"

echo ""
echo "═══════════════════════════════════════"
echo "  Setup complete!"
echo "═══════════════════════════════════════"
echo ""
echo "Run benchmarks:"
echo "  bash bench/debug/run.sh                    # all languages, all variants"
echo "  bash bench/debug/run.sh python debug       # one language, one variant"
echo "  bash bench/debug/run.sh 'python cpp' debug # multiple languages"
echo ""
echo "View results:"
echo "  open bench/debug/dashboard.html"
