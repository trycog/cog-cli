#!/usr/bin/env bash
# Compile Go debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.go"  /tmp/debug_test.go
cp "$SCRIPT_DIR/debug_crash.go" /tmp/debug_crash.go
cp "$SCRIPT_DIR/debug_sleep.go" /tmp/debug_sleep.go
cp "$SCRIPT_DIR/debug_vars.go"  /tmp/debug_vars.go

# Compile all four programs with debug info and no optimization
go build -gcflags="all=-N -l" -o /tmp/debug_test_go  /tmp/debug_test.go
go build -gcflags="all=-N -l" -o /tmp/debug_crash_go /tmp/debug_crash.go
go build -gcflags="all=-N -l" -o /tmp/debug_sleep_go /tmp/debug_sleep.go
go build -gcflags="all=-N -l" -o /tmp/debug_vars_go  /tmp/debug_vars.go

echo "All Go test fixtures compiled in /tmp/"
