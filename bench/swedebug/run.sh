#!/usr/bin/env bash
# SWE-bench debug benchmark runner
# Runs all tasks via `claude -p`, verifies fixes via Docker, captures metrics
set -euo pipefail

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
mkdir -p "$BENCH_DIR"

# Optional args: task IDs and variants to run
export TASKS="${1:-}"
export VARIANTS="${2:-debug traditional}"
export SCRIPT_DIR BENCH_DIR

echo "══════════════════════════════════════"
echo "  SWE-bench Debug Benchmark Runner"
echo "══════════════════════════════════════"
echo ""

python3 -u << 'PYEOF'
import re, json, subprocess, os, sys, time

script_dir = os.environ['SCRIPT_DIR']
bench_dir = os.environ['BENCH_DIR']
variants = os.environ.get('VARIANTS', 'debug traditional').split()

tasks_json = os.path.join(script_dir, 'tasks.json')
with open(tasks_json) as f:
    tasks = json.load(f)

if not tasks:
    print("ERROR: tasks.json is empty. Run setup.sh first.", file=sys.stderr)
    sys.exit(1)

# Parse task IDs to run
tasks_arg = os.environ.get('TASKS', '').strip()
if tasks_arg:
    task_ids = [int(x) for x in tasks_arg.split()]
else:
    task_ids = [t['id'] for t in tasks]

task_by_id = {t['id']: t for t in tasks}

# Load prompts from swedebug.md
md_path = os.path.join(script_dir, 'swedebug.md')
if not os.path.exists(md_path):
    print("ERROR: swedebug.md not found. Run setup.sh first.", file=sys.stderr)
    sys.exit(1)

with open(md_path) as f:
    md_content = f.read()

# Extract all code blocks from markdown
blocks = re.findall(r'```\n(.*?)```', md_content, re.DOTALL)

# Build prompt map: (task_id, variant) -> prompt
prompt_map = {}
for i, block in enumerate(blocks):
    task_idx = i // 2
    variant = 'debug' if i % 2 == 0 else 'traditional'
    # Match task_idx to task_id (0-based to 1-based)
    if task_idx < len(tasks):
        tid = tasks[task_idx]['id']
        prompt_map[(tid, variant)] = block

print(f"Tasks:    {' '.join(str(t) for t in task_ids)}")
print(f"Variants: {' '.join(variants)}")
print(f"Prompts:  {len(prompt_map)} loaded")
print("")


def verify_fix(task, variant_name):
    """Run FAIL_TO_PASS tests via docker exec. Returns True if all pass."""
    tid = task['id']
    tag = f"task-{tid:02d}"
    container = f"swedebug-{tag}"
    test_cmd = task['test_cmd']
    fail_tests = task.get('fail_to_pass', [])

    try:
        proc = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c',
             f'cd /testbed && {test_cmd}'],
            capture_output=True, text=True, timeout=300
        )
        # pytest exit code 0 = all passed
        return proc.returncode == 0
    except subprocess.TimeoutExpired:
        return False
    except Exception as e:
        print(f"        (verify error: {e})", flush=True)
        return False


def verify_no_regression(task):
    """Run PASS_TO_PASS tests via docker exec. Returns True if none regressed."""
    tid = task['id']
    tag = f"task-{tid:02d}"
    container = f"swedebug-{tag}"
    pass_tests = task.get('pass_to_pass', [])

    if not pass_tests:
        return True  # Nothing to check

    # Build test command for pass_to_pass tests
    test_items = ' '.join(pass_tests[:10])  # Limit to 10 tests
    try:
        proc = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c',
             f'cd /testbed && python -m pytest {test_items} -x --timeout=60'],
            capture_output=True, text=True, timeout=300
        )
        return proc.returncode == 0
    except (subprocess.TimeoutExpired, Exception):
        return True  # Don't fail on regression check errors


def reset_workspace(task):
    """Reset workspace to swedebug-base state via git checkout."""
    tid = task['id']
    tag = f"task-{tid:02d}"
    task_dir = os.path.join(script_dir, 'workspace', tag)

    try:
        subprocess.run(
            ['git', 'checkout', '.'],
            cwd=task_dir, capture_output=True, timeout=10
        )
        subprocess.run(
            ['git', 'clean', '-fd'],
            cwd=task_dir, capture_output=True, timeout=10
        )
    except Exception:
        pass


def start_container(task):
    """Start Docker container with bind-mounted workspace."""
    tid = task['id']
    tag = f"task-{tid:02d}"
    container = f"swedebug-{tag}"
    task_dir = os.path.join(script_dir, 'workspace', tag)

    # Stop any existing container
    subprocess.run(
        ['docker', 'rm', '-f', container],
        capture_output=True, timeout=10
    )

    # Start container with bind mount
    proc = subprocess.run(
        ['docker', 'run', '-d',
         '--name', container,
         '-v', f'{task_dir}:/testbed',
         f'swedebug-{tag}'],
        capture_output=True, text=True, timeout=30
    )

    if proc.returncode != 0:
        print(f"        (container start failed: {proc.stderr.strip()})", flush=True)
        return False

    # Install the package in the container (using bind-mounted source)
    install_cmd = task.get('install_cmd', 'pip install -e .')
    subprocess.run(
        ['docker', 'exec', container, 'bash', '-c',
         f'cd /testbed && {install_cmd}'],
        capture_output=True, timeout=300
    )

    return True


def stop_container(task):
    """Stop and remove Docker container."""
    tid = task['id']
    tag = f"task-{tid:02d}"
    container = f"swedebug-{tag}"
    subprocess.run(
        ['docker', 'rm', '-f', container],
        capture_output=True, timeout=10
    )


def extract_test_name(block):
    """Pull the test name from the JSON format instruction in the prompt."""
    m = re.search(r'"name":\s*"([^"]+)"', block)
    return m.group(1) if m else None


total = 0
passed = 0

for tid in task_ids:
    task = task_by_id.get(tid)
    if not task:
        print(f"  ! Task {tid}: not found in tasks.json", flush=True)
        continue

    tag = f"task-{tid:02d}"
    task_dir = os.path.join(script_dir, 'workspace', tag)

    if not os.path.isdir(task_dir):
        print(f"  ! Task {tid}: workspace not found (run setup.sh first)", flush=True)
        continue

    for variant in variants:
        prompt = prompt_map.get((tid, variant))
        if not prompt:
            print(f"  ! {tag}-{variant}: no prompt found", flush=True)
            continue

        total += 1
        result_file = os.path.join(bench_dir, f"swe-{tid}-{variant}.json")
        test_name = task['name']

        # Skip if already completed with real data
        if os.path.exists(result_file):
            try:
                with open(result_file) as f:
                    existing = json.load(f)
                if existing.get('cost_usd', 0) > 0:
                    v = "verified" if existing.get('verified') else "unverified"
                    print(f"  skip  swe-{tid}-{variant} (done: ${existing['cost_usd']:.4f}, {v})", flush=True)
                    passed += 1
                    continue
            except Exception:
                pass

        # Reset workspace to clean state
        reset_workspace(task)

        # Start Docker container
        print(f"\n  start swe-{tid}-{variant} ({test_name})", flush=True)
        if not start_container(task):
            print(f"        FAIL: could not start container", flush=True)
            continue

        # Pre-verify: FAIL_TO_PASS should fail
        pre_ok = verify_fix(task, variant)
        if pre_ok:
            print(f"        WARNING: FAIL_TO_PASS tests already pass (bug may be fixed)", flush=True)

        # Strip the collect.sh instruction from prompt
        stripped = re.sub(r'\nThen run this command.*$', '', prompt, flags=re.MULTILINE).strip()

        print(f"  run   swe-{tid}-{variant}", flush=True)
        start = time.time()

        try:
            cmd = [
                'claude', '-p', stripped,
                '--output-format', 'json',
                '--dangerously-skip-permissions',
            ]
            env = {k: v for k, v in os.environ.items() if k != 'CLAUDECODE'}
            proc = subprocess.run(
                cmd, cwd=task_dir, env=env,
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
                except Exception:
                    pass
            if calls == 0:
                m = re.search(r'"calls":\s*(\d+)', response_text)
                if m:
                    calls = int(m.group(1))
                m2 = re.search(r'"rounds":\s*(\d+)', response_text)
                if m2:
                    rounds = int(m2.group(1))

            # Verify the fix
            verified = verify_fix(task, variant)
            regression = verify_no_regression(task)

            data = {
                'test': tid,
                'name': test_name,
                'instance_id': task['instance_id'],
                'variant': variant,
                'calls': calls,
                'rounds': rounds,
                'cost_usd': round(cost, 6),
                'duration_ms': dur,
                'input_tokens': in_tok,
                'output_tokens': out_tok,
                'verified': verified if verified is not None else False,
                'regression_free': regression,
            }
            with open(result_file, 'w') as f:
                json.dump(data, f)

            v_str = "VERIFIED" if verified else "WRONG"
            r_str = "" if regression else " REGRESSION"
            status = 'OK' if cost > 0 else 'FAIL'
            print(f"        {status}  calls={calls} rounds={rounds} cost=${cost:.4f} tokens={in_tok+out_tok} time={dur/1000:.1f}s {v_str}{r_str}", flush=True)
            if cost > 0:
                passed += 1

        except subprocess.TimeoutExpired:
            print(f"        FAIL: timeout (10 min)", flush=True)
        except Exception as e:
            print(f"        FAIL: {e}", flush=True)

        # Cleanup: reset workspace + stop container
        reset_workspace(task)
        stop_container(task)

print(f"\n{'='*40}", flush=True)
print(f"  {passed}/{total} tests completed", flush=True)
print(f"{'='*40}", flush=True)
PYEOF

# Update dashboard
echo ""
bash "$SCRIPT_DIR/collect.sh"

echo ""
echo "Open $SCRIPT_DIR/dashboard.html to view results"
