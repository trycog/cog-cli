#!/usr/bin/env bash
# Collect benchmark results from .bench/*.json and inline into dashboard.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
DASHBOARD="$SCRIPT_DIR/dashboard.html"

if [[ ! -d "$BENCH_DIR" ]]; then
  echo "No .bench/ directory found. Run some benchmarks first."
  exit 1
fi

count=$(find "$BENCH_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$count" -eq 0 ]]; then
  echo "No result files found in .bench/"
  exit 1
fi

echo "Found $count result files"

# Build the inline script block
INLINE_SCRIPT=$(python3 -c "
import json, glob, os, sys

bench_dir = '$BENCH_DIR'
files = sorted(glob.glob(os.path.join(bench_dir, '*.json')))

results = []
for f in files:
    try:
        with open(f) as fh:
            results.append(json.load(fh))
    except Exception as e:
        print(f'  warning: skipping {f}: {e}', file=sys.stderr)

lang_tests = {
    'react':   {'name': 'React',   'language': 'javascript', 'tests': range(1, 6)},
    'gin':     {'name': 'Gin',     'language': 'go',         'tests': range(6, 11)},
    'flask':   {'name': 'Flask',   'language': 'python',     'tests': range(11, 16)},
    'ripgrep': {'name': 'ripgrep', 'language': 'rust',       'tests': range(16, 21)},
}

by_key = {}
for r in results:
    key = (r.get('test'), r.get('variant'))
    by_key[key] = r

languages = []
for lang_key, lang_info in lang_tests.items():
    lang_results = []
    for test_num in lang_info['tests']:
        explore = by_key.get((test_num, 'explore'), {})
        traditional = by_key.get((test_num, 'traditional'), {})
        name = explore.get('name') or traditional.get('name') or f'Test {test_num}'
        lang_results.append({
            'name': name,
            'explore': {
                'calls': explore.get('calls', 0),
                'rounds': explore.get('rounds', 0),
                'cost_usd': explore.get('cost_usd', 0),
                'duration_ms': explore.get('duration_ms', 0),
                'input_tokens': explore.get('input_tokens', 0),
                'output_tokens': explore.get('output_tokens', 0),
                'pass': explore.get('cost_usd', 0) > 0,
            },
            'traditional': {
                'calls': traditional.get('calls', 0),
                'rounds': traditional.get('rounds', 0),
                'cost_usd': traditional.get('cost_usd', 0),
                'duration_ms': traditional.get('duration_ms', 0),
                'input_tokens': traditional.get('input_tokens', 0),
                'output_tokens': traditional.get('output_tokens', 0),
                'pass': traditional.get('cost_usd', 0) > 0,
            },
        })
    languages.append({
        'name': lang_info['name'],
        'language': lang_info['language'],
        'results': lang_results,
    })

data = {
    'model': '',
    'date': '',
    'languages': languages,
}

print('const EXPLORE_DATA = ' + json.dumps(data, indent=2) + ';')
print(f'Loaded {len(results)} results', file=sys.stderr)
")

# Replace the data block between markers in dashboard.html
python3 << PYEOF
import re, sys

with open('$DASHBOARD', 'r') as f:
    html = f.read()

pattern = r'<!-- EXPLORE_DATA_START -->.*?<!-- EXPLORE_DATA_END -->'
inline = '''$INLINE_SCRIPT'''
replacement = '<!-- EXPLORE_DATA_START -->\n<script>\n' + inline + '\n</script>\n<!-- EXPLORE_DATA_END -->'

new_html = re.sub(pattern, replacement, html, flags=re.DOTALL)

if new_html == html:
    print('ERROR: Could not find EXPLORE_DATA markers in dashboard.html', file=sys.stderr)
    sys.exit(1)

with open('$DASHBOARD', 'w') as f:
    f.write(new_html)
PYEOF

echo "Inlined $count results into $DASHBOARD"
echo "Open $DASHBOARD to view"
