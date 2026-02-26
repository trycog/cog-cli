#!/usr/bin/env bash
# Collect SWE-bench benchmark results and inline into dashboard.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
RESULTS_DIR="$SCRIPT_DIR/results"
DASHBOARD="$SCRIPT_DIR/dashboard.html"
TASKS_JSON="$SCRIPT_DIR/tasks.json"

if [[ ! -d "$BENCH_DIR" ]]; then
  echo "No .bench/ directory found. Run some benchmarks first."
  exit 1
fi

count=$(find "$BENCH_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$count" -eq 0 ]]; then
  echo "No result files found in .bench/"
  exit 1
fi

echo "Found $count result files in .bench/"

# Check for SWE-bench evaluation results
for variant in baseline debugger; do
  report="$RESULTS_DIR/$variant/results.json"
  if [[ -f "$report" ]]; then
    echo "Found SWE-bench eval results for $variant"
  fi
done

# Build the inline script block
INLINE_SCRIPT=$(python3 -c "
import json, glob, os, sys

bench_dir = '$BENCH_DIR'
results_dir = '$RESULTS_DIR'
tasks_json = '$TASKS_JSON'

# Load task definitions
with open(tasks_json) as f:
    tasks = json.load(f)

# Load run metrics from .bench/
metrics = {}
for f_path in sorted(glob.glob(os.path.join(bench_dir, '*.json'))):
    try:
        with open(f_path) as fh:
            data = json.load(fh)
        key = (data.get('instance_id', ''), data.get('variant', ''))
        if key[0] and key[1]:
            metrics[key] = data
    except Exception as e:
        print(f'  warning: skipping {f_path}: {e}', file=sys.stderr)

# Load SWE-bench evaluation results (resolved instance IDs)
resolved = {}  # variant -> set of resolved instance_ids
for variant in ['baseline', 'debugger']:
    resolved[variant] = set()
    # Try multiple result file locations
    for fname in ['results.json', 'report.json']:
        report_path = os.path.join(results_dir, variant, fname)
        if os.path.exists(report_path):
            try:
                with open(report_path) as fh:
                    report = json.load(fh)
                # SWE-bench format: {\"resolved\": [...instance_ids...]}
                if isinstance(report, dict):
                    for iid in report.get('resolved', []):
                        resolved[variant].add(iid)
            except Exception as e:
                print(f'  warning: could not parse {report_path}: {e}', file=sys.stderr)

# Build per-task results
task_results = []
for task in tasks:
    iid = task['instance_id']
    repo = task['repo']

    baseline = metrics.get((iid, 'baseline'), {})
    debugger = metrics.get((iid, 'debugger'), {})

    b_resolved = iid in resolved.get('baseline', set())
    d_resolved = iid in resolved.get('debugger', set())

    task_results.append({
        'instance_id': iid,
        'repo': repo,
        'baseline': {
            'cost_usd': baseline.get('cost_usd', 0),
            'duration_ms': baseline.get('duration_ms', 0),
            'num_turns': baseline.get('num_turns', 0),
            'input_tokens': baseline.get('input_tokens', 0),
            'output_tokens': baseline.get('output_tokens', 0),
            'has_patch': baseline.get('has_patch', False),
            'patch_size': baseline.get('patch_size', 0),
            'resolved': b_resolved,
            'timeout': baseline.get('timeout', False),
        },
        'debugger': {
            'cost_usd': debugger.get('cost_usd', 0),
            'duration_ms': debugger.get('duration_ms', 0),
            'num_turns': debugger.get('num_turns', 0),
            'input_tokens': debugger.get('input_tokens', 0),
            'output_tokens': debugger.get('output_tokens', 0),
            'has_patch': debugger.get('has_patch', False),
            'patch_size': debugger.get('patch_size', 0),
            'resolved': d_resolved,
            'timeout': debugger.get('timeout', False),
            'debug_tool_calls': debugger.get('debug_tool_calls', 0),
        },
    })

# Compute aggregates
b_resolved_count = sum(1 for t in task_results if t['baseline']['resolved'])
d_resolved_count = sum(1 for t in task_results if t['debugger']['resolved'])
b_total_tokens = sum(t['baseline']['input_tokens'] + t['baseline']['output_tokens'] for t in task_results)
d_total_tokens = sum(t['debugger']['input_tokens'] + t['debugger']['output_tokens'] for t in task_results)
b_total_cost = sum(t['baseline']['cost_usd'] for t in task_results)
d_total_cost = sum(t['debugger']['cost_usd'] for t in task_results)
b_ran = sum(1 for t in task_results if t['baseline']['cost_usd'] > 0 or t['baseline'].get('timeout'))
d_ran = sum(1 for t in task_results if t['debugger']['cost_usd'] > 0 or t['debugger'].get('timeout'))

# Debugger advantage: tasks resolved by debugger but not baseline
advantage = sum(1 for t in task_results if t['debugger']['resolved'] and not t['baseline']['resolved'])
disadvantage = sum(1 for t in task_results if t['baseline']['resolved'] and not t['debugger']['resolved'])

d_used_tools = sum(1 for t in task_results if t['debugger'].get('debug_tool_calls', 0) > 0)
d_no_tools = sum(1 for t in task_results if t['debugger']['cost_usd'] > 0 and t['debugger'].get('debug_tool_calls', 0) == 0)

data = {
    'total_tasks': len(tasks),
    'baseline_ran': b_ran,
    'debugger_ran': d_ran,
    'baseline_resolved': b_resolved_count,
    'debugger_resolved': d_resolved_count,
    'debugger_advantage': advantage,
    'debugger_disadvantage': disadvantage,
    'baseline_total_tokens': b_total_tokens,
    'debugger_total_tokens': d_total_tokens,
    'baseline_total_cost': round(b_total_cost, 2),
    'debugger_total_cost': round(d_total_cost, 2),
    'debugger_used_tools': d_used_tools,
    'debugger_no_tools': d_no_tools,
    'tasks': task_results,
}

print('const SWEBENCH_DATA = ' + json.dumps(data, indent=2) + ';')
print(f'Collected {len(task_results)} tasks ({b_ran} baseline, {d_ran} debugger runs)', file=sys.stderr)
print(f'Resolved: baseline={b_resolved_count}, debugger={d_resolved_count} (advantage: +{advantage}, -{disadvantage})', file=sys.stderr)
print(f'Debugger tool usage: {d_used_tools} used tools, {d_no_tools} did NOT use tools', file=sys.stderr)
if d_no_tools > 0:
    print(f'WARNING: {d_no_tools} debugger runs completed without using any cog_debug tools', file=sys.stderr)
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

echo "Inlined $count results into $DASHBOARD"
echo "Open $DASHBOARD to view"
