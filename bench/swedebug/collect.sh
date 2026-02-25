#!/usr/bin/env bash
# Collect SWE-bench benchmark results from .bench/swe-*.json and inline into dashboard.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
DASHBOARD="$SCRIPT_DIR/dashboard.html"
TASKS_JSON="$SCRIPT_DIR/tasks.json"

if [[ ! -d "$BENCH_DIR" ]]; then
  echo "No .bench/ directory found. Run some benchmarks first."
  exit 1
fi

count=$(find "$BENCH_DIR" -name 'swe-*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$count" -eq 0 ]]; then
  echo "No SWE result files found in .bench/"
  exit 1
fi

echo "Found $count result files"

# Build the inline script block
INLINE_SCRIPT=$(python3 -c "
import json, glob, os, sys

bench_dir = '$BENCH_DIR'
tasks_json = '$TASKS_JSON'

files = sorted(glob.glob(os.path.join(bench_dir, 'swe-*.json')))

results = []
for f in files:
    try:
        with open(f) as fh:
            results.append(json.load(fh))
    except Exception as e:
        print(f'  warning: skipping {f}: {e}', file=sys.stderr)

# Load task definitions for names
with open(tasks_json) as f:
    tasks = json.load(f)
task_by_id = {t['id']: t for t in tasks}

by_key = {}
for r in results:
    key = (r.get('test'), r.get('variant'))
    by_key[key] = r

task_results = []
for task in tasks:
    tid = task['id']
    debug = by_key.get((tid, 'debug'), {})
    traditional = by_key.get((tid, 'traditional'), {})
    name = task.get('name', f'Task {tid}')
    instance_id = task.get('instance_id', '')
    task_results.append({
        'name': name,
        'instance_id': instance_id,
        'debug': {
            'calls': debug.get('calls', 0),
            'rounds': debug.get('rounds', 0),
            'cost_usd': debug.get('cost_usd', 0),
            'duration_ms': debug.get('duration_ms', 0),
            'input_tokens': debug.get('input_tokens', 0),
            'output_tokens': debug.get('output_tokens', 0),
            'pass': debug.get('cost_usd', 0) > 0,
            'verified': debug.get('verified', False),
        },
        'traditional': {
            'calls': traditional.get('calls', 0),
            'rounds': traditional.get('rounds', 0),
            'cost_usd': traditional.get('cost_usd', 0),
            'duration_ms': traditional.get('duration_ms', 0),
            'input_tokens': traditional.get('input_tokens', 0),
            'output_tokens': traditional.get('output_tokens', 0),
            'pass': traditional.get('cost_usd', 0) > 0,
            'verified': traditional.get('verified', False),
        },
    })

data = {
    'model': '',
    'date': '',
    'tasks': task_results,
}

print('const SWE_DATA = ' + json.dumps(data, indent=2) + ';')
print(f'Loaded {len(results)} results', file=sys.stderr)
")

# Replace the data block between markers in dashboard.html
python3 << PYEOF
import re, sys

with open('$DASHBOARD', 'r') as f:
    html = f.read()

pattern = r'<!-- SWE_DATA_START -->.*?<!-- SWE_DATA_END -->'
inline = '''$INLINE_SCRIPT'''
replacement = '<!-- SWE_DATA_START -->\n<script>\n' + inline + '\n</script>\n<!-- SWE_DATA_END -->'

new_html = re.sub(pattern, replacement, html, flags=re.DOTALL)

if new_html == html:
    print('ERROR: Could not find SWE_DATA markers in dashboard.html', file=sys.stderr)
    sys.exit(1)

with open('$DASHBOARD', 'w') as f:
    f.write(new_html)
PYEOF

echo "Inlined $count results into $DASHBOARD"
echo "Open $DASHBOARD to view"
