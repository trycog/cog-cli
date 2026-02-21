#!/usr/bin/env bash
# Copy JavaScript debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.js"  /tmp/debug_test.js
cp "$SCRIPT_DIR/debug_crash.js" /tmp/debug_crash.js
cp "$SCRIPT_DIR/debug_sleep.js" /tmp/debug_sleep.js
cp "$SCRIPT_DIR/debug_vars.js"  /tmp/debug_vars.js

echo "All JavaScript test fixtures copied to /tmp/"
