#!/usr/bin/env bash
# Automated benchmark runner
# Runs all tests via `claude -p` and captures metrics from CLI output
set -euo pipefail

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
mkdir -p "$BENCH_DIR"

# Optional args: repos and variants to run
export REPOS="${1:-react gin flask ripgrep}"
export VARIANTS="${2:-explore traditional}"
export SCRIPT_DIR BENCH_DIR

echo "══════════════════════════════════════"
echo "  Cog Explore Benchmark Runner"
echo "══════════════════════════════════════"
echo ""
echo "Repos:    $REPOS"
echo "Variants: $VARIANTS"
echo ""

python3 -u << 'PYEOF'
import re, json, subprocess, os, sys, time

script_dir = os.environ['SCRIPT_DIR']
bench_dir = os.environ['BENCH_DIR']
repos = os.environ.get('REPOS', 'react gin flask ripgrep').split()
variants = os.environ.get('VARIANTS', 'explore traditional').split()

repo_config = {
    'react':   ('react.md',   range(1, 6)),
    'gin':     ('gin.md',     range(6, 11)),
    'flask':   ('flask.md',   range(11, 16)),
    'ripgrep': ('ripgrep.md', range(16, 21)),
}

# Extract test names from markdown file prompts
def extract_test_name(block):
    """Pull the test name from the JSON format instruction in the prompt."""
    m = re.search(r'"name":\s*"([^"]+)"', block)
    return m.group(1) if m else None

total = 0
passed = 0

for repo in repos:
    if repo not in repo_config:
        print(f"Unknown repo: {repo}", file=sys.stderr)
        continue

    md_file, test_range = repo_config[repo]
    md_path = os.path.join(script_dir, md_file)
    repo_dir = os.path.join(script_dir, repo)

    if not os.path.isdir(repo_dir):
        print(f"  ! {repo}: not found — run setup.sh first", flush=True)
        continue

    with open(md_path) as f:
        content = f.read()

    blocks = re.findall(r'```\n(.*?)```', content, re.DOTALL)
    test_nums = list(test_range)

    for i, block in enumerate(blocks):
        test_idx = i // 2
        variant = 'explore' if i % 2 == 0 else 'traditional'

        if test_idx >= len(test_nums):
            break
        if variant not in variants:
            continue

        test_num = test_nums[test_idx]
        total += 1

        result_file = os.path.join(bench_dir, f"{repo}-{test_num}-{variant}.json")
        test_name = extract_test_name(block) or f"Test {test_num}"

        # Skip if already completed with real data
        if os.path.exists(result_file):
            try:
                with open(result_file) as f:
                    existing = json.load(f)
                if existing.get('cost_usd', 0) > 0:
                    print(f"  skip  {repo}-{test_num}-{variant} (done: ${existing['cost_usd']:.4f})", flush=True)
                    passed += 1
                    continue
            except:
                pass

        # Strip the collect.sh instruction from prompt
        prompt = re.sub(r'\nThen run this command.*$', '', block, flags=re.MULTILINE).strip()

        print(f"\n  run   {repo}-{test_num}-{variant} ({test_name})", flush=True)
        start = time.time()

        try:
            cmd = [
                'claude', '-p', prompt,
                '--output-format', 'json',
                '--dangerously-skip-permissions',
            ]
            env = {k: v for k, v in os.environ.items() if k != 'CLAUDECODE'}
            proc = subprocess.run(
                cmd, cwd=repo_dir, env=env,
                capture_output=True, text=True, timeout=600
            )

            elapsed = int((time.time() - start) * 1000)
            cost = 0
            dur = elapsed
            in_tok = 0
            out_tok = 0
            num_turns = 0
            response_text = ''

            try:
                out = json.loads(proc.stdout)
                cost = out.get('total_cost_usd', 0) or 0
                dur = out.get('duration_ms', 0) or elapsed
                num_turns = out.get('num_turns', 0) or 0
                response_text = out.get('result', '') or ''
                for m, u in (out.get('modelUsage') or {}).items():
                    in_tok += u.get('inputTokens', 0) + u.get('cacheReadInputTokens', 0) + u.get('cacheCreationInputTokens', 0)
                    out_tok += u.get('outputTokens', 0)
            except Exception as e:
                print(f"        (parse error: {e})", flush=True)

            # Try to get self-reported calls/rounds from Claude's response
            calls = 0
            rounds = num_turns  # CLI num_turns = rounds
            # Check if Claude wrote a result file with self-reported data
            if os.path.exists(result_file):
                try:
                    with open(result_file) as f:
                        claude_data = json.load(f)
                    if claude_data.get('calls', 0) > 0:
                        calls = claude_data['calls']
                    if claude_data.get('rounds', 0) > 0:
                        rounds = claude_data['rounds']
                except:
                    pass
            # Also try to parse from response text as fallback
            if calls == 0:
                m = re.search(r'"calls":\s*(\d+)', response_text)
                if m:
                    calls = int(m.group(1))
                m2 = re.search(r'"rounds":\s*(\d+)', response_text)
                if m2:
                    rounds = int(m2.group(1))

            data = {
                'test': test_num,
                'name': test_name,
                'variant': variant,
                'calls': calls,
                'rounds': rounds,
                'cost_usd': round(cost, 6),
                'duration_ms': dur,
                'input_tokens': in_tok,
                'output_tokens': out_tok,
            }
            with open(result_file, 'w') as f:
                json.dump(data, f)

            status = 'OK' if cost > 0 else 'FAIL'
            print(f"        {status}  calls={calls} rounds={rounds} cost=${cost:.4f} tokens={in_tok+out_tok} time={dur/1000:.1f}s", flush=True)
            if cost > 0:
                passed += 1

        except subprocess.TimeoutExpired:
            print(f"        FAIL: timeout (10 min)", flush=True)
        except Exception as e:
            print(f"        FAIL: {e}", flush=True)

print(f"\n{'='*40}", flush=True)
print(f"  {passed}/{total} tests completed", flush=True)
print(f"{'='*40}", flush=True)
PYEOF

# Update dashboard
echo ""
bash "$SCRIPT_DIR/collect.sh"

echo ""
echo "Open $SCRIPT_DIR/dashboard.html to view results"
