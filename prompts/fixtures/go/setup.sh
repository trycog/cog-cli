#!/usr/bin/env bash
# Compile Go debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build a Go fixture in a stable directory under /tmp.
# Uses a persistent build directory so DWARF source paths remain valid
# (the debugger needs the source file to exist at the path recorded in DWARF).
build_go_fixture() {
    local src="$1" target_name="$2" builddir="$3" output="$4"
    rm -rf "$builddir"
    mkdir -p "$builddir"
    cp "$src" "$builddir/$target_name"
    (cd "$builddir" && go mod init fixture && go build -gcflags="all=-N -l" -ldflags="-compressdwarf=false" -o "$output" .)
}

# Build all fixtures
# Note: debug_test.go is renamed to debug_basic.go to avoid Go's _test.go convention
build_go_fixture "$SCRIPT_DIR/debug_test.go"  "debug_basic.go" "/tmp/debug_basic" "/tmp/debug_test_go"
build_go_fixture "$SCRIPT_DIR/debug_crash.go" "debug_crash.go" "/tmp/debug_crash" "/tmp/debug_crash_go"
build_go_fixture "$SCRIPT_DIR/debug_sleep.go" "debug_sleep.go" "/tmp/debug_sleep" "/tmp/debug_sleep_go"
build_go_fixture "$SCRIPT_DIR/debug_vars.go"  "debug_vars.go"  "/tmp/debug_vars"  "/tmp/debug_vars_go"

echo "All Go test fixtures compiled in /tmp/"
