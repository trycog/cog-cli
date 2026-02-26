#!/usr/bin/env bash
# SWE-bench Pro benchmark runner (SWE-agent based)
#
# Invokes `sweagent run-batch` for each variant, then converts predictions to JSONL.
#
# Usage:
#   bash bench/swebench/run.sh [baseline|debugger-subagent|all] [max_tasks] [num_workers]
#
# Examples:
#   bash bench/swebench/run.sh all              # all tasks, all variants
#   bash bench/swebench/run.sh baseline 2       # baseline only, first 2 tasks
#   bash bench/swebench/run.sh debugger-subagent 5 2  # debugger, 5 tasks, 2 workers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
COG_BIN="$ROOT_DIR/zig-out/bin/cog"
TASKS_JSONL="$SCRIPT_DIR/tasks_sweagent.jsonl"

VARIANT_ARG="${1:-all}"
MAX_TASKS="${2:-0}"
NUM_WORKERS="${3:-1}"

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

echo "══════════════════════════════════════"
echo "  SWE-bench Pro Benchmark Runner"
echo "  (SWE-agent scaffold)"
echo "══════════════════════════════════════"
echo ""
echo "  Variant:     $VARIANT_ARG"
echo "  Max tasks:   ${MAX_TASKS:-all}"
echo "  Workers:     $NUM_WORKERS"
echo ""

# ── Validate ────────────────────────────────────────────────────────────

if [[ ! -f "$TASKS_JSONL" ]]; then
  echo "ERROR: tasks_sweagent.jsonl not found. Run setup.sh first."
  exit 1
fi

if ! command -v sweagent &>/dev/null; then
  echo "ERROR: sweagent not found. Run setup.sh first."
  exit 1
fi

# Determine variants to run
if [[ "$VARIANT_ARG" == "all" ]]; then
  VARIANTS=("baseline" "debugger-subagent")
elif [[ "$VARIANT_ARG" == "baseline" || "$VARIANT_ARG" == "debugger-subagent" ]]; then
  VARIANTS=("$VARIANT_ARG")
else
  echo "ERROR: Unknown variant '$VARIANT_ARG'. Use: baseline, debugger-subagent, or all"
  exit 1
fi

mkdir -p "$PREDICTIONS_DIR"

# ── Prepare instance file (optionally sliced) ──────────────────────────

INSTANCE_FILE="$TASKS_JSONL"
if [[ "$MAX_TASKS" -gt 0 ]]; then
  INSTANCE_FILE="$SCRIPT_DIR/.tasks_sliced.jsonl"
  head -n "$MAX_TASKS" "$TASKS_JSONL" > "$INSTANCE_FILE"
  task_count=$(wc -l < "$INSTANCE_FILE" | tr -d ' ')
  echo "Sliced to $task_count tasks"
  echo ""
fi

# ── Run each variant ─────────────────────────────────────────────────

for variant in "${VARIANTS[@]}"; do
  echo "════════════════════════════════════"
  echo "  Running variant: $variant"
  echo "════════════════════════════════════"
  echo ""

  CONFIG="$SCRIPT_DIR/configs/${variant}.yaml"
  if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Config not found: $CONFIG"
    exit 1
  fi

  OUTPUT_DIR="$SCRIPT_DIR/trajectories/${variant}"
  mkdir -p "$OUTPUT_DIR"

  # Build sweagent command
  SWEAGENT_CMD=(
    sweagent run-batch
    --config "$CONFIG"
    --instances.type file
    --instances.path "$INSTANCE_FILE"
    --num_workers "$NUM_WORKERS"
    --output_dir "$OUTPUT_DIR"
  )

  # For debugger-subagent, use our wrapper with CogDebugAgent
  if [[ "$variant" == "debugger-subagent" ]]; then
    export COG_DEBUG_AGENT=1
    export COG_BIN="$COG_BIN"

    SWEAGENT_CMD=(
      python3 "$SCRIPT_DIR/run_sweagent.py"
      run-batch
      --config "$CONFIG"
      --instances.type file
      --instances.path "$INSTANCE_FILE"
      --num_workers "$NUM_WORKERS"
      --output_dir "$OUTPUT_DIR"
    )
  fi

  echo "  Command: ${SWEAGENT_CMD[*]}"
  echo ""

  # Run SWE-agent
  "${SWEAGENT_CMD[@]}" 2>&1 | tee "$SCRIPT_DIR/logs/${variant}.log" || {
    echo ""
    echo "  WARNING: sweagent exited with non-zero status for $variant"
    echo "  Check logs: $SCRIPT_DIR/logs/${variant}.log"
    echo ""
  }

  # Unset debugger-subagent env vars
  unset COG_DEBUG_AGENT 2>/dev/null || true

  echo ""
  echo "  $variant complete. Output: $OUTPUT_DIR"
  echo ""

  # Convert predictions to JSONL
  echo "  Converting predictions..."
  python3 "$SCRIPT_DIR/convert_preds.py" "$variant" "$OUTPUT_DIR"
  echo ""
done

# ── Summary ────────────────────────────────────────────────────────────

echo "══════════════════════════════════════"
echo "  All variants complete"
echo "══════════════════════════════════════"
echo ""
echo "Predictions in: $PREDICTIONS_DIR/"
for variant in "${VARIANTS[@]}"; do
  pred_file="$PREDICTIONS_DIR/${variant}.jsonl"
  if [[ -f "$pred_file" ]]; then
    count=$(wc -l < "$pred_file" | tr -d ' ')
    echo "  $variant: $count predictions"
  fi
done
echo ""
echo "Next steps:"
echo "  bash bench/swebench/evaluate.sh"
echo "  bash bench/swebench/collect.sh"
echo "  open bench/swebench/dashboard.html"
