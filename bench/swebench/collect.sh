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
for variant in baseline debugger debugger-lite; do
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

ALL_VARIANTS = ['baseline', 'debugger', 'debugger-lite']
DEBUG_VARIANTS = ['debugger', 'debugger-lite']

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
for variant in ALL_VARIANTS:
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

def build_variant_data(m, is_resolved, is_debug=False):
    \"\"\"Build per-task data for a variant from its metrics dict.\"\"\"
    d = {
        'cost_usd': m.get('cost_usd', 0),
        'duration_ms': m.get('duration_ms', 0),
        'num_turns': m.get('num_turns', 0),
        'input_tokens': m.get('input_tokens', 0),
        'output_tokens': m.get('output_tokens', 0),
        'has_patch': m.get('has_patch', False),
        'patch_size': m.get('patch_size', 0),
        'resolved': is_resolved,
        'timeout': m.get('timeout', False),
    }
    if is_debug:
        d['debug_tool_calls'] = m.get('debug_tool_calls', 0)
        d['sessions_launched'] = m.get('sessions_launched', 0)
        d['breakpoints_set'] = m.get('breakpoints_set', 0)
        d['conditional_breakpoints'] = m.get('conditional_breakpoints', 0)
    return d

# Build per-task results
task_results = []
for task in tasks:
    iid = task['instance_id']
    repo = task['repo']

    baseline = metrics.get((iid, 'baseline'), {})
    debugger = metrics.get((iid, 'debugger'), {})
    debugger_lite = metrics.get((iid, 'debugger-lite'), {})

    entry = {
        'instance_id': iid,
        'repo': repo,
        'baseline': build_variant_data(baseline, iid in resolved['baseline']),
        'debugger': build_variant_data(debugger, iid in resolved['debugger'], is_debug=True),
        'debugger_lite': build_variant_data(debugger_lite, iid in resolved['debugger-lite'], is_debug=True),
    }
    task_results.append(entry)

# Compute aggregates per variant
def aggregate(tasks, key):
    ran = sum(1 for t in tasks if t[key]['cost_usd'] > 0 or t[key].get('timeout'))
    resolved_count = sum(1 for t in tasks if t[key]['resolved'])
    total_tokens = sum(t[key]['input_tokens'] + t[key]['output_tokens'] for t in tasks)
    total_cost = sum(t[key]['cost_usd'] for t in tasks)
    return ran, resolved_count, total_tokens, total_cost

b_ran, b_resolved_count, b_total_tokens, b_total_cost = aggregate(task_results, 'baseline')
d_ran, d_resolved_count, d_total_tokens, d_total_cost = aggregate(task_results, 'debugger')
dl_ran, dl_resolved_count, dl_total_tokens, dl_total_cost = aggregate(task_results, 'debugger_lite')

# Debugger advantage: tasks resolved by debugger but not baseline
advantage = sum(1 for t in task_results if t['debugger']['resolved'] and not t['baseline']['resolved'])
disadvantage = sum(1 for t in task_results if t['baseline']['resolved'] and not t['debugger']['resolved'])
dl_advantage = sum(1 for t in task_results if t['debugger_lite']['resolved'] and not t['baseline']['resolved'])
dl_disadvantage = sum(1 for t in task_results if t['baseline']['resolved'] and not t['debugger_lite']['resolved'])

d_used_tools = sum(1 for t in task_results if t['debugger'].get('debug_tool_calls', 0) > 0)
d_no_tools = sum(1 for t in task_results if t['debugger']['cost_usd'] > 0 and t['debugger'].get('debug_tool_calls', 0) == 0)
dl_used_tools = sum(1 for t in task_results if t['debugger_lite'].get('debug_tool_calls', 0) > 0)
dl_no_tools = sum(1 for t in task_results if t['debugger_lite']['cost_usd'] > 0 and t['debugger_lite'].get('debug_tool_calls', 0) == 0)

data = {
    'total_tasks': len(tasks),
    'baseline_ran': b_ran,
    'debugger_ran': d_ran,
    'debugger_lite_ran': dl_ran,
    'baseline_resolved': b_resolved_count,
    'debugger_resolved': d_resolved_count,
    'debugger_lite_resolved': dl_resolved_count,
    'debugger_advantage': advantage,
    'debugger_disadvantage': disadvantage,
    'debugger_lite_advantage': dl_advantage,
    'debugger_lite_disadvantage': dl_disadvantage,
    'baseline_total_tokens': b_total_tokens,
    'debugger_total_tokens': d_total_tokens,
    'debugger_lite_total_tokens': dl_total_tokens,
    'baseline_total_cost': round(b_total_cost, 2),
    'debugger_total_cost': round(d_total_cost, 2),
    'debugger_lite_total_cost': round(dl_total_cost, 2),
    'debugger_used_tools': d_used_tools,
    'debugger_no_tools': d_no_tools,
    'debugger_lite_used_tools': dl_used_tools,
    'debugger_lite_no_tools': dl_no_tools,
    'tasks': task_results,
}

print('const SWEBENCH_DATA = ' + json.dumps(data, indent=2) + ';')
print(f'Collected {len(task_results)} tasks ({b_ran} baseline, {d_ran} debugger, {dl_ran} debugger-lite runs)', file=sys.stderr)
print(f'Resolved: baseline={b_resolved_count}, debugger={d_resolved_count}, debugger-lite={dl_resolved_count}', file=sys.stderr)
print(f'Debugger advantage: +{advantage}/-{disadvantage}  Debugger-lite advantage: +{dl_advantage}/-{dl_disadvantage}', file=sys.stderr)
print(f'Debugger tool usage: {d_used_tools} used, {d_no_tools} skipped  |  Lite: {dl_used_tools} used, {dl_no_tools} skipped', file=sys.stderr)
if d_no_tools > 0:
    print(f'WARNING: {d_no_tools} debugger runs completed without using any cog_debug tools', file=sys.stderr)
if dl_no_tools > 0:
    print(f'WARNING: {dl_no_tools} debugger-lite runs completed without using any cog_debug tools', file=sys.stderr)
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
