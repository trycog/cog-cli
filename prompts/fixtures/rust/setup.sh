#!/usr/bin/env bash
# Compile Rust debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.rs"  /tmp/debug_test.rs
cp "$SCRIPT_DIR/debug_crash.rs" /tmp/debug_crash.rs
cp "$SCRIPT_DIR/debug_sleep.rs" /tmp/debug_sleep.rs
cp "$SCRIPT_DIR/debug_vars.rs"  /tmp/debug_vars.rs

# Compile all four programs with debug info
rustc -g -o /tmp/debug_test_rs  /tmp/debug_test.rs
rustc -g -o /tmp/debug_crash_rs /tmp/debug_crash.rs
rustc -g -o /tmp/debug_sleep_rs /tmp/debug_sleep.rs
rustc -g -o /tmp/debug_vars_rs  /tmp/debug_vars.rs

echo "All Rust test fixtures compiled in /tmp/"
