#!/usr/bin/env bash
# Run official SWE-bench evaluation on prediction JSONL files
#
# Usage:
#   bash bench/swebench/evaluate.sh              # evaluate all variants
#   bash bench/swebench/evaluate.sh baseline      # evaluate specific variant
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
RESULTS_DIR="$SCRIPT_DIR/results"
VARIANT="${1:-}"

echo "══════════════════════════════════════"
echo "  SWE-bench Evaluation"
echo "══════════════════════════════════════"
echo ""

# Check swebench is installed
if ! python3 -c "import swebench" 2>/dev/null; then
  echo "ERROR: swebench package not installed"
  echo "  pip install swebench"
  exit 1
fi

# Determine which variants to evaluate
if [[ -n "$VARIANT" ]]; then
  variants=("$VARIANT")
else
  variants=()
  for f in "$PREDICTIONS_DIR"/*.jsonl; do
    if [[ -f "$f" ]]; then
      name=$(basename "$f" .jsonl)
      variants+=("$name")
    fi
  done
fi

if [[ ${#variants[@]} -eq 0 ]]; then
  echo "ERROR: No prediction files found in $PREDICTIONS_DIR/"
  echo "  Run benchmarks first: bash bench/swebench/run.sh"
  exit 1
fi

echo "Variants to evaluate: ${variants[*]}"
echo ""

mkdir -p "$RESULTS_DIR"

for variant in "${variants[@]}"; do
  pred_file="$PREDICTIONS_DIR/${variant}.jsonl"

  if [[ ! -f "$pred_file" ]]; then
    echo "  SKIP $variant: no prediction file at $pred_file"
    continue
  fi

  pred_count=$(wc -l < "$pred_file" | tr -d ' ')
  echo "  Evaluating $variant ($pred_count predictions)..."

  run_id="cog-swebench-${variant}"
  variant_results="$RESULTS_DIR/${variant}"
  mkdir -p "$variant_results"

  python -m swebench.harness.run_evaluation \
    --dataset_name princeton-nlp/SWE-bench_Lite \
    --predictions_path "$pred_file" \
    --max_workers 4 \
    --run_id "$run_id" \
    --cache_level env \
    --namespace '' \
    2>&1 | tee "$variant_results/eval.log"

  # Copy results to variant directory
  if [[ -d "$run_id" ]]; then
    cp -r "$run_id"/* "$variant_results/" 2>/dev/null || true
    rm -rf "$run_id"
  fi

  echo "  $variant evaluation complete -> $variant_results/"
  echo ""
done

echo "══════════════════════════════════════"
echo "  Evaluation complete"
echo "══════════════════════════════════════"
echo ""
echo "Results in: $RESULTS_DIR/"
echo ""
echo "Next steps:"
echo "  bash bench/swebench/collect.sh"
echo "  open bench/swebench/dashboard.html"
