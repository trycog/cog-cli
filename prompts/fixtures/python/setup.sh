#!/usr/bin/env bash
# Copy Python debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.py"  /tmp/debug_test.py
cp "$SCRIPT_DIR/debug_crash.py" /tmp/debug_crash.py
cp "$SCRIPT_DIR/debug_sleep.py" /tmp/debug_sleep.py
cp "$SCRIPT_DIR/debug_vars.py"  /tmp/debug_vars.py

echo "All Python test fixtures copied to /tmp/"
