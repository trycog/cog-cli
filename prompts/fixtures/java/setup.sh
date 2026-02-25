#!/usr/bin/env bash
# Compile Java debug test fixtures to /tmp for e2e testing.
# Run this before starting debug server e2e test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy source files to /tmp (overwrites any modified versions)
cp "$SCRIPT_DIR/DebugTest.java"  /tmp/DebugTest.java
cp "$SCRIPT_DIR/DebugCrash.java" /tmp/DebugCrash.java
cp "$SCRIPT_DIR/DebugSleep.java" /tmp/DebugSleep.java
cp "$SCRIPT_DIR/DebugVars.java"  /tmp/DebugVars.java

# Compile all four programs with full debug information
javac -g -d /tmp /tmp/DebugTest.java
javac -g -d /tmp /tmp/DebugCrash.java
javac -g -d /tmp /tmp/DebugSleep.java
javac -g -d /tmp /tmp/DebugVars.java

echo "All Java test fixtures compiled in /tmp/"
