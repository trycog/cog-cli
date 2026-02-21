#!/usr/bin/env bash
# Compile C++ debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.cpp"  /tmp/debug_test.cpp
cp "$SCRIPT_DIR/debug_crash.cpp" /tmp/debug_crash.cpp
cp "$SCRIPT_DIR/debug_sleep.cpp" /tmp/debug_sleep.cpp
cp "$SCRIPT_DIR/debug_vars.cpp"  /tmp/debug_vars.cpp

# Compile all four programs with debug info and no optimization
c++ -g -O0 -o /tmp/debug_test_cpp  /tmp/debug_test.cpp
c++ -g -O0 -o /tmp/debug_crash_cpp /tmp/debug_crash.cpp
c++ -g -O0 -o /tmp/debug_sleep_cpp /tmp/debug_sleep.cpp
c++ -g -O0 -o /tmp/debug_vars_cpp  /tmp/debug_vars.cpp

echo "All C++ test fixtures compiled in /tmp/"
