#!/usr/bin/env bash
# SWE-bench Lite benchmark runner
# Runs baseline and/or debugger variants via `claude -p`, captures patches and metrics
#
# Usage:
#   bash bench/swebench/run.sh [baseline|debugger|all] [max_tasks] [timeout]
#
# Examples:
#   bash bench/swebench/run.sh all              # all tasks, both variants
#   bash bench/swebench/run.sh baseline 2       # baseline only, first 2 tasks
#   bash bench/swebench/run.sh debugger 5 1200  # debugger, 5 tasks, 20min timeout
set -euo pipefail

# Allow nested claude invocations when run from within Claude Code
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BENCH_DIR="$SCRIPT_DIR/.bench"
PREDICTIONS_DIR="$SCRIPT_DIR/predictions"
LOGS_DIR="$SCRIPT_DIR/logs"
WORKSPACE="$SCRIPT_DIR/workspace"
COG_BIN="$ROOT_DIR/zig-out/bin/cog"

mkdir -p "$BENCH_DIR" "$PREDICTIONS_DIR" "$LOGS_DIR"

VARIANT_ARG="${1:-all}"
MAX_TASKS="${2:-0}"
TIMEOUT="${3:-900}"

export SCRIPT_DIR ROOT_DIR BENCH_DIR PREDICTIONS_DIR LOGS_DIR WORKSPACE COG_BIN
export VARIANT_ARG MAX_TASKS TIMEOUT

echo "══════════════════════════════════════"
echo "  SWE-bench Lite Benchmark Runner"
echo "══════════════════════════════════════"
echo ""
echo "  Variant:  $VARIANT_ARG"
echo "  Max tasks: ${MAX_TASKS:-all}"
echo "  Timeout:  ${TIMEOUT}s"
echo ""

python3 -u << 'PYEOF'
import json, os, subprocess, sys, time, re

# Strip Claude Code env vars so nested claude invocations work
for _k in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT'):
    os.environ.pop(_k, None)

script_dir = os.environ['SCRIPT_DIR']
bench_dir = os.environ['BENCH_DIR']
predictions_dir = os.environ['PREDICTIONS_DIR']
logs_dir = os.environ['LOGS_DIR']
workspace = os.environ['WORKSPACE']
cog_bin = os.environ['COG_BIN']
variant_arg = os.environ.get('VARIANT_ARG', 'all')
max_tasks = int(os.environ.get('MAX_TASKS', '0'))
timeout = int(os.environ.get('TIMEOUT', '900'))

tasks_json = os.path.join(script_dir, 'tasks.json')
with open(tasks_json) as f:
    tasks = json.load(f)

if not tasks:
    print("ERROR: tasks.json is empty. Run setup.sh first.", file=sys.stderr)
    sys.exit(1)

# Determine variants to run
if variant_arg == 'all':
    variants = ['baseline', 'debugger']
elif variant_arg in ('baseline', 'debugger'):
    variants = [variant_arg]
else:
    print(f"ERROR: Unknown variant '{variant_arg}'. Use: baseline, debugger, or all", file=sys.stderr)
    sys.exit(1)

# Limit tasks if requested
if max_tasks > 0:
    tasks = tasks[:max_tasks]

# Load prompt templates
def load_template(name):
    path = os.path.join(script_dir, 'prompts', f'{name}.txt')
    with open(path) as f:
        return f.read()

templates = {
    'baseline': load_template('baseline'),
    'debugger': load_template('debugger'),
}

# MCP configs — CLI-driven isolation, no .mcp.json files
MCP_CONFIGS = {
    'baseline': json.dumps({"mcpServers": {}}),
    'debugger': json.dumps({"mcpServers": {"cog": {"command": cog_bin, "args": ["mcp"]}}}),
}

print(f"Tasks:    {len(tasks)}")
print(f"Variants: {' '.join(variants)}")
print(f"Timeout:  {timeout}s per task")
print("")


def build_prompt(task, variant):
    """Build prompt from template with task field substitution."""
    template = templates[variant]
    fail_to_pass = task.get('FAIL_TO_PASS', [])
    if isinstance(fail_to_pass, list):
        fail_str = '\n'.join(f'- {t}' for t in fail_to_pass)
    else:
        fail_str = str(fail_to_pass)

    return template.format(
        repo=task['repo'],
        instance_id=task['instance_id'],
        problem_statement=task['problem_statement'],
        fail_to_pass=fail_str,
    )


def reset_workspace(task_dir):
    """Reset workspace to swebench-base state."""
    try:
        subprocess.run(
            ['git', 'checkout', 'swebench-base'],
            cwd=task_dir, capture_output=True, timeout=10
        )
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


def extract_patch(task_dir):
    """Extract git diff against swebench-base (what the agent changed)."""
    try:
        proc = subprocess.run(
            ['git', 'diff', 'swebench-base'],
            cwd=task_dir, capture_output=True, text=True, timeout=30
        )
        return proc.stdout.strip()
    except Exception:
        return ""


def append_prediction(variant, instance_id, patch):
    """Append a prediction to the variant's JSONL file."""
    pred = {
        "instance_id": instance_id,
        "model_name_or_path": f"cog-swebench-{variant}",
        "model_patch": patch,
    }
    path = os.path.join(predictions_dir, f'{variant}.jsonl')
    with open(path, 'a') as f:
        f.write(json.dumps(pred) + '\n')


total = 0
completed = 0

# Run variants sequentially: all baseline first, then all debugger
for variant in variants:
    print(f"\n{'='*50}")
    print(f"  Running variant: {variant}")
    print(f"{'='*50}")

    for i, task in enumerate(tasks):
        instance_id = task['instance_id']
        task_dir = os.path.join(workspace, instance_id)

        if not os.path.isdir(task_dir):
            print(f"\n  ! [{i+1}/{len(tasks)}] {instance_id}: workspace not found (run setup.sh)", flush=True)
            continue

        total += 1
        result_file = os.path.join(bench_dir, f'{instance_id}-{variant}.json')

        # Skip if already completed with cost > 0 (resume support)
        if os.path.exists(result_file):
            try:
                with open(result_file) as f:
                    existing = json.load(f)
                if existing.get('cost_usd', 0) > 0:
                    print(f"\n  skip [{i+1}/{len(tasks)}] {instance_id}-{variant} (done: ${existing['cost_usd']:.4f})", flush=True)
                    completed += 1
                    continue
            except Exception:
                pass

        # Reset workspace
        reset_workspace(task_dir)

        print(f"\n  run  [{i+1}/{len(tasks)}] {instance_id}-{variant}", flush=True)
        start = time.time()

        # Build prompt
        prompt = build_prompt(task, variant)

        log_file = os.path.join(logs_dir, f'{instance_id}-{variant}.jsonl')

        try:
            cmd = [
                'claude', '-p', prompt,
                '--output-format', 'stream-json',
                '--verbose',
                '--model', 'opus',
                '--dangerously-skip-permissions',
                '--strict-mcp-config',
                '--mcp-config', MCP_CONFIGS[variant],
            ]
            env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')}

            # Stream output live: write to log file and parse in real-time
            cost = 0
            dur = 0
            in_tok = 0
            out_tok = 0
            num_turns = 0
            debug_tool_calls = 0

            proc = subprocess.Popen(
                cmd, cwd=task_dir, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1
            )

            log_fh = open(log_file, 'w')
            try:
                for line in proc.stdout:
                    log_fh.write(line)
                    log_fh.flush()
                    line = line.strip()
                    if not line:
                        continue

                    # Print live summary of each message
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    msg_type = msg.get('type', '')

                    # Show assistant text and tool calls live
                    if msg_type == 'assistant':
                        content = msg.get('message', {}).get('content', [])
                        if isinstance(content, list):
                            for block in content:
                                if isinstance(block, dict):
                                    if block.get('type') == 'tool_use':
                                        tool_name = block.get('name', '')
                                        print(f"       > tool: {tool_name}", flush=True)
                                        if 'cog_debug' in tool_name:
                                            debug_tool_calls += 1
                                    elif block.get('type') == 'text':
                                        text = block.get('text', '')
                                        if text.strip():
                                            preview = text.strip().replace('\n', ' ')[:120]
                                            print(f"       > {preview}", flush=True)

                    elif msg_type == 'tool_result':
                        pass  # tool results can be huge, skip

                    elif msg_type == 'result':
                        cost = msg.get('total_cost_usd', 0) or 0
                        dur = msg.get('duration_ms', 0) or 0
                        num_turns = msg.get('num_turns', 0) or 0
                        for m, u in (msg.get('modelUsage') or {}).items():
                            in_tok += u.get('inputTokens', 0) + u.get('cacheReadInputTokens', 0) + u.get('cacheCreationInputTokens', 0)
                            out_tok += u.get('outputTokens', 0)

                proc.wait(timeout=timeout)
            finally:
                stderr = proc.stderr.read() if proc.stderr else ''
                if stderr:
                    with open(log_file + '.stderr', 'w') as f:
                        f.write(stderr)
                log_fh.close()

            elapsed = int((time.time() - start) * 1000)
            if dur == 0:
                dur = elapsed

            # Extract patch
            patch = extract_patch(task_dir)
            has_patch = bool(patch)
            patch_size = len(patch)

            # Append to predictions JSONL
            append_prediction(variant, instance_id, patch)

            # Record metrics
            data = {
                'instance_id': instance_id,
                'variant': variant,
                'cost_usd': round(cost, 6),
                'duration_ms': dur,
                'num_turns': num_turns,
                'input_tokens': in_tok,
                'output_tokens': out_tok,
                'has_patch': has_patch,
                'patch_size': patch_size,
                'debug_tool_calls': debug_tool_calls,
                'log_file': log_file,
            }
            with open(result_file, 'w') as f:
                json.dump(data, f, indent=2)

            total_tokens = in_tok + out_tok
            status = 'OK' if cost > 0 else 'FAIL'
            patch_str = f"patch={patch_size}B" if has_patch else "no-patch"
            dbg_str = f" debug_tools={debug_tool_calls}" if variant == 'debugger' else ""
            if variant == 'debugger' and debug_tool_calls == 0 and cost > 0:
                dbg_str += " WARNING:NO_DEBUG_TOOLS_USED"
            print(f"       {status}  cost=${cost:.4f} tokens={total_tokens} turns={num_turns} time={dur/1000:.1f}s {patch_str}{dbg_str}", flush=True)
            if cost > 0:
                completed += 1

        except subprocess.TimeoutExpired:
            elapsed = int((time.time() - start) * 1000)
            print(f"       TIMEOUT ({timeout}s)", flush=True)
            try:
                proc.kill()
                proc.wait(timeout=5)
            except Exception:
                pass
            # Still extract whatever patch exists
            patch = extract_patch(task_dir)
            if patch:
                append_prediction(variant, instance_id, patch)
            data = {
                'instance_id': instance_id,
                'variant': variant,
                'cost_usd': round(cost, 6),
                'duration_ms': elapsed,
                'num_turns': num_turns,
                'input_tokens': in_tok,
                'output_tokens': out_tok,
                'has_patch': bool(patch),
                'patch_size': len(patch) if patch else 0,
                'debug_tool_calls': debug_tool_calls,
                'timeout': True,
            }
            with open(result_file, 'w') as f:
                json.dump(data, f, indent=2)

        except Exception as e:
            print(f"       FAIL: {e}", flush=True)

        # Reset workspace for next run
        reset_workspace(task_dir)

print(f"\n{'='*50}")
print(f"  {completed}/{total} runs completed")
print(f"{'='*50}")
print(f"\nPredictions written to {predictions_dir}/")
print(f"Run evaluation:  bash bench/swebench/evaluate.sh")
print(f"Collect results: bash bench/swebench/collect.sh")
PYEOF
