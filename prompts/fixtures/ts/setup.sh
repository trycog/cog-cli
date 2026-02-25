#!/usr/bin/env bash
# Compile TypeScript debug test fixtures to /private/tmp/ts/ for e2e testing.
# Run this before starting debug server e2e test scenarios.
# Requires: tsc (TypeScript compiler) — install via: npm install -g typescript
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p /private/tmp/ts

# Copy source files to /private/tmp/ts/ (overwrites any modified versions)
cp "$SCRIPT_DIR/debug_test.ts"  /private/tmp/ts/debug_test.ts
cp "$SCRIPT_DIR/debug_crash.ts" /private/tmp/ts/debug_crash.ts
cp "$SCRIPT_DIR/debug_sleep.ts" /private/tmp/ts/debug_sleep.ts
cp "$SCRIPT_DIR/debug_vars.ts"  /private/tmp/ts/debug_vars.ts

# Compile all programs with source maps for debugging.
# Source maps enable breakpoints on .ts files while running compiled .js.
# Type errors about missing @types/node are expected and don't prevent emission.
cd /private/tmp/ts && tsc --sourceMap --target es2020 --module commonjs --esModuleInterop \
    debug_test.ts debug_crash.ts debug_sleep.ts debug_vars.ts 2>/dev/null || true

# Verify compilation produced output
for f in debug_test.js debug_crash.js debug_sleep.js debug_vars.js; do
    if [ ! -f "/private/tmp/ts/$f" ]; then
        echo "ERROR: /private/tmp/ts/$f was not generated" >&2
        exit 1
    fi
done

echo "All TypeScript test fixtures compiled in /private/tmp/ts/"
