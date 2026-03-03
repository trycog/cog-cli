#!/usr/bin/env bash
# Collect SWE-bench benchmark results and inline into dashboard.html
#
# Reads run_claude.py metadata and evaluation results,
# produces a JavaScript data object inlined into dashboard.html.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
LOGS_DIR="$SCRIPT_DIR/logs"
DASHBOARD="$SCRIPT_DIR/dashboard.html"
TASKS_JSON="$SCRIPT_DIR/tasks.json"

if [[ ! -f "$TASKS_JSON" ]]; then
  echo "No tasks.json found. Run setup.sh first."
  exit 1
fi

# Check for results
has_results=false
for variant in baseline debugger; do
  report="$RESULTS_DIR/$variant/results.json"
  if [[ -f "$report" ]]; then
    echo "Found evaluation results for $variant"
    has_results=true
  fi
done

if ! $has_results; then
  echo "No evaluation results found. Run evaluate.sh first."
  exit 1
fi

# Build the inline script block
INLINE_SCRIPT=$(python3 -c "
import json, glob, os, sys

results_dir = '$RESULTS_DIR'
predictions_dir = '$PREDICTIONS_DIR'
logs_dir = '$LOGS_DIR'
tasks_json = '$TASKS_JSON'

ALL_VARIANTS = ['baseline', 'debugger']

# Load task definitions
with open(tasks_json) as f:
    tasks = json.load(f)

# Load SWE-bench evaluation results (resolved instance IDs)
resolved = {}
for variant in ALL_VARIANTS:
    resolved[variant] = set()
    for fname in ['results.json', 'report.json']:
        report_path = os.path.join(results_dir, variant, fname)
        if os.path.exists(report_path):
            try:
                with open(report_path) as fh:
                    report = json.load(fh)
                if isinstance(report, dict):
                    for iid in report.get('resolved', []):
                        resolved[variant].add(iid)
            except Exception as e:
                print(f'  warning: could not parse {report_path}: {e}', file=sys.stderr)

# Load prediction counts
pred_counts = {}
for variant in ALL_VARIANTS:
    pred_path = os.path.join(predictions_dir, f'{variant}.jsonl')
    if os.path.exists(pred_path):
        with open(pred_path) as f:
            pred_counts[variant] = sum(1 for line in f if line.strip())
    else:
        pred_counts[variant] = 0

# Load run metadata from run_claude.py logs
run_meta = {}  # (instance_id, variant) -> {cost_usd, duration_seconds, ...}
for variant in ALL_VARIANTS:
    meta_path = os.path.join(logs_dir, f'{variant}_metadata.json')
    if os.path.exists(meta_path):
        try:
            with open(meta_path) as fh:
                meta_list = json.load(fh)
            # Match metadata to predictions by index
            pred_path = os.path.join(predictions_dir, f'{variant}.jsonl')
            if os.path.exists(pred_path):
                with open(pred_path) as fh:
                    preds = [json.loads(line) for line in fh if line.strip()]
                for pred, meta in zip(preds, meta_list):
                    iid = pred['instance_id']
                    run_meta[(iid, variant)] = meta
        except Exception as e:
            print(f'  warning: could not parse {meta_path}: {e}', file=sys.stderr)

# Build per-task results
task_results = []
for task in tasks:
    iid = task['instance_id']
    repo = task['repo']

    entry = {
        'instance_id': iid,
        'repo': repo,
    }
    for variant in ALL_VARIANTS:
        vkey = variant.replace('-', '_')
        is_resolved = iid in resolved[variant]
        meta = run_meta.get((iid, variant), {})
        entry[vkey] = {
            'resolved': is_resolved,
            'has_patch': bool(meta.get('success', False)),
            'cost_usd': meta.get('cost_usd', 0),
            'duration_seconds': meta.get('duration_seconds', 0),
            'num_turns': meta.get('num_turns', 0),
        }
    task_results.append(entry)

# Compute aggregates per variant
b_ran = pred_counts.get('baseline', 0)
d_ran = pred_counts.get('debugger', 0)
b_resolved = sum(1 for t in task_results if t['baseline']['resolved'])
d_resolved = sum(1 for t in task_results if t['debugger']['resolved'])

# Debugger advantage: resolved by debugger but not baseline
advantage = sum(1 for t in task_results if t['debugger']['resolved'] and not t['baseline']['resolved'])
disadvantage = sum(1 for t in task_results if t['baseline']['resolved'] and not t['debugger']['resolved'])

data = {
    'total_tasks': len(tasks),
    'baseline_ran': b_ran,
    'debugger_ran': d_ran,
    'baseline_resolved': b_resolved,
    'debugger_resolved': d_resolved,
    'debugger_advantage': advantage,
    'debugger_disadvantage': disadvantage,
    'tasks': task_results,
}

print('const SWEBENCH_DATA = ' + json.dumps(data, indent=2) + ';')
print(f'Collected {len(task_results)} tasks ({b_ran} baseline, {d_ran} debugger runs)', file=sys.stderr)
print(f'Resolved: baseline={b_resolved}, debugger={d_resolved}', file=sys.stderr)
print(f'Advantage: +{advantage}/-{disadvantage}', file=sys.stderr)
")

# Replace the data block between markers in dashboard.html
python3 << PYEOF
import re, sys

with open('$DASHBOARD', 'r') as f:
    html = f.read()

pattern = r'<!-- SWEBENCH_DATA_START -->.*?<!-- SWEBENCH_DATA_END -->'
inline = '''$INLINE_SCRIPT'''
replacement = '<!-- SWEBENCH_DATA_START -->\n<script>\n' + inline + '\n</script>\n<!-- SWEBENCH_DATA_END -->'

new_html = re.sub(pattern, replacement, html, flags=re.DOTALL)

if new_html == html:
    print('ERROR: Could not find SWEBENCH_DATA markers in dashboard.html', file=sys.stderr)
    sys.exit(1)

with open('$DASHBOARD', 'w') as f:
    f.write(new_html)
PYEOF

echo "Inlined results into $DASHBOARD"
echo "Open $DASHBOARD to view"
