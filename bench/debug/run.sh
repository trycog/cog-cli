#!/usr/bin/env bash
# Automated debug benchmark runner
# Runs all tests via `claude -p`, verifies fixes, captures metrics
set -euo pipefail

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
mkdir -p "$BENCH_DIR"

# Optional args: languages and variants to run
export LANGS="${1:-python javascript cpp rust}"
export VARIANTS="${2:-debug traditional}"
export SCRIPT_DIR BENCH_DIR

echo "══════════════════════════════════════"
echo "  Cog Debug Benchmark Runner"
echo "══════════════════════════════════════"
echo ""
echo "Languages: $LANGS"
echo "Variants:  $VARIANTS"
echo ""

python3 -u << 'PYEOF'
import re, json, subprocess, os, sys, time, shutil

script_dir = os.environ['SCRIPT_DIR']
bench_dir = os.environ['BENCH_DIR']
langs = os.environ.get('LANGS', 'python javascript cpp rust').split()
variants = os.environ.get('VARIANTS', 'debug traditional').split()

lang_config = {
    'python':     ('python.md',     range(1, 6)),
    'javascript': ('javascript.md', range(6, 11)),
    'cpp':        ('cpp.md',        range(11, 16)),
    'rust':       ('rust.md',       range(16, 21)),
}

# Test directory mapping
test_dirs = {
    1: 'python/01-logic-error',
    2: 'python/02-state-mutation',
    3: 'python/03-crash',
    4: 'python/04-concurrency',
    5: 'python/05-silent-wrong',
    6: 'javascript/01-logic-error',
    7: 'javascript/02-state-mutation',
    8: 'javascript/03-crash',
    9: 'javascript/04-concurrency',
    10: 'javascript/05-silent-wrong',
    11: 'cpp/01-logic-error',
    12: 'cpp/02-state-mutation',
    13: 'cpp/03-crash',
    14: 'cpp/04-concurrency',
    15: 'cpp/05-silent-wrong',
    16: 'rust/01-logic-error',
    17: 'rust/02-state-mutation',
    18: 'rust/03-crash',
    19: 'rust/04-concurrency',
    20: 'rust/05-silent-wrong',
}

# Run commands to verify a fix worked
def verify_fix(test_num, lang):
    """Run the program and compare stdout to expected_output.txt."""
    test_rel = test_dirs.get(test_num, '')
    test_dir = os.path.join(script_dir, test_rel)
    expected_file = os.path.join(test_dir, 'expected_output.txt')

    if not os.path.exists(expected_file):
        return None  # Can't verify without expected output

    with open(expected_file) as f:
        expected = f.read().strip()

    try:
        if lang == 'python':
            main_py = os.path.join(test_dir, 'main.py')
            proc = subprocess.run(['python3', main_py], capture_output=True, text=True, timeout=30, cwd=test_dir)
        elif lang == 'javascript':
            main_js = os.path.join(test_dir, 'main.js')
            proc = subprocess.run(['node', main_js], capture_output=True, text=True, timeout=30, cwd=test_dir)
        elif lang == 'cpp':
            # Recompile first
            subprocess.run(['make', '-C', test_dir, '-s'], capture_output=True, timeout=30)
            program = os.path.join(test_dir, 'program')
            proc = subprocess.run([program], capture_output=True, text=True, timeout=30, cwd=test_dir)
        elif lang == 'rust':
            # Recompile first
            subprocess.run(['cargo', 'build'], capture_output=True, timeout=60, cwd=test_dir)
            proc = subprocess.run(['cargo', 'run'], capture_output=True, text=True, timeout=30, cwd=test_dir)
        else:
            return None

        actual = proc.stdout.strip()
        return actual == expected
    except (subprocess.TimeoutExpired, Exception) as e:
        return False


def reset_test(test_num):
    """Reset test source files to their original (broken) state via git."""
    test_rel = test_dirs.get(test_num, '')
    if not test_rel:
        return

    test_path = os.path.join('bench/debug', test_rel)
    try:
        subprocess.run(
            ['git', 'checkout', '--', test_path],
            capture_output=True, cwd=os.path.join(script_dir, '../..'),
            timeout=10
        )
    except Exception:
        pass


def extract_test_name(block):
    """Pull the test name from the JSON format instruction in the prompt."""
    m = re.search(r'"name":\s*"([^"]+)"', block)
    return m.group(1) if m else None


total = 0
passed = 0

for lang in langs:
    if lang not in lang_config:
        print(f"Unknown language: {lang}", file=sys.stderr)
        continue

    md_file, test_range = lang_config[lang]
    md_path = os.path.join(script_dir, md_file)
    lang_dir = os.path.join(script_dir, lang)

    if not os.path.isdir(lang_dir):
        print(f"  ! {lang}: directory not found", flush=True)
        continue

    with open(md_path) as f:
        content = f.read()

    blocks = re.findall(r'```\n(.*?)```', content, re.DOTALL)
    test_nums = list(test_range)

    for i, block in enumerate(blocks):
        test_idx = i // 2
        variant = 'debug' if i % 2 == 0 else 'traditional'

        if test_idx >= len(test_nums):
            break
        if variant not in variants:
            continue

        test_num = test_nums[test_idx]
        total += 1

        result_file = os.path.join(bench_dir, f"{lang}-{test_num}-{variant}.json")
        test_name = extract_test_name(block) or f"Test {test_num}"

        # Skip if already completed with real data
        if os.path.exists(result_file):
            try:
                with open(result_file) as f:
                    existing = json.load(f)
                if existing.get('cost_usd', 0) > 0:
                    v = "verified" if existing.get('verified') else "unverified"
                    print(f"  skip  {lang}-{test_num}-{variant} (done: ${existing['cost_usd']:.4f}, {v})", flush=True)
                    passed += 1
                    continue
            except:
                pass

        # Reset test files to broken state before running
        reset_test(test_num)

        # Strip the collect.sh instruction from prompt
        prompt = re.sub(r'\nThen run this command.*$', '', block, flags=re.MULTILINE).strip()

        print(f"\n  run   {lang}-{test_num}-{variant} ({test_name})", flush=True)
        start = time.time()

        try:
            cmd = [
                'claude', '-p', prompt,
                '--output-format', 'json',
                '--dangerously-skip-permissions',
            ]
            env = {k: v for k, v in os.environ.items() if k != 'CLAUDECODE'}
            proc = subprocess.run(
                cmd, cwd=lang_dir, env=env,
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
            rounds = num_turns
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
            if calls == 0:
                m = re.search(r'"calls":\s*(\d+)', response_text)
                if m:
                    calls = int(m.group(1))
                m2 = re.search(r'"rounds":\s*(\d+)', response_text)
                if m2:
                    rounds = int(m2.group(1))

            # Verify the fix by running the program
            verified = verify_fix(test_num, lang)

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
                'verified': verified if verified is not None else False,
            }
            with open(result_file, 'w') as f:
                json.dump(data, f)

            v_str = "VERIFIED" if verified else ("UNVERIFIED" if verified is None else "WRONG")
            status = 'OK' if cost > 0 else 'FAIL'
            print(f"        {status}  calls={calls} rounds={rounds} cost=${cost:.4f} tokens={in_tok+out_tok} time={dur/1000:.1f}s {v_str}", flush=True)
            if cost > 0:
                passed += 1

            # Reset test files after run (restore broken source for next variant)
            reset_test(test_num)

        except subprocess.TimeoutExpired:
            print(f"        FAIL: timeout (10 min)", flush=True)
            reset_test(test_num)
        except Exception as e:
            print(f"        FAIL: {e}", flush=True)
            reset_test(test_num)

print(f"\n{'='*40}", flush=True)
print(f"  {passed}/{total} tests completed", flush=True)
print(f"{'='*40}", flush=True)
PYEOF

# Update dashboard
echo ""
bash "$SCRIPT_DIR/collect.sh"

echo ""
echo "Open $SCRIPT_DIR/dashboard.html to view results"
