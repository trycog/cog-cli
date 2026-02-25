#!/usr/bin/env bash
# Setup script for SWE-bench debug benchmarks
# Clones repos, builds Docker images, generates prompts, configures Claude
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COG_BIN="${COG_BIN:-zig-out/bin/cog}"
TASKS_JSON="$SCRIPT_DIR/tasks.json"
WORKSPACE="$SCRIPT_DIR/workspace"
DOCKER_DIR="$SCRIPT_DIR/docker"

echo "═══════════════════════════════════════"
echo "  SWE-bench Debug Benchmark Setup"
echo "═══════════════════════════════════════"
echo ""

# ── Validate tasks.json ──────────────────────────────────────────────────

task_count=$(python3 -c "import json; print(len(json.load(open('$TASKS_JSON'))))")
if [[ "$task_count" -eq 0 ]]; then
  echo "ERROR: tasks.json is empty."
  echo ""
  echo "Run select_tasks.py first to find candidates:"
  echo "  pip install datasets"
  echo "  python3 bench/swedebug/select_tasks.py"
  echo ""
  echo "Then populate tasks.json with 5 tasks and re-run setup.sh."
  exit 1
fi
echo "Found $task_count tasks in tasks.json"

# ── Check dependencies ───────────────────────────────────────────────────

echo ""
echo "Checking dependencies..."
missing=()

if ! command -v docker &>/dev/null; then
  missing+=("docker")
fi

if ! command -v python3 &>/dev/null; then
  missing+=("python3")
fi

if ! command -v git &>/dev/null; then
  missing+=("git")
fi

if ! command -v claude &>/dev/null; then
  missing+=("claude (Claude Code CLI)")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "  ERROR: Missing dependencies: ${missing[*]}"
  echo "  Install them and re-run setup.sh"
  exit 1
fi

echo "  docker:  $(docker --version 2>&1 | head -1)"
echo "  python3: $(python3 --version 2>&1)"
echo "  git:     $(git --version 2>&1)"
echo "  claude:  $(claude --version 2>&1 | head -1)"

# ── Build cog binary ────────────────────────────────────────────────────

if [[ ! -f "$ROOT_DIR/$COG_BIN" ]]; then
  echo ""
  echo "Building cog binary..."
  (cd "$ROOT_DIR" && zig build)
fi
COG="$ROOT_DIR/$COG_BIN"

# ── Settings ─────────────────────────────────────────────────────────────

SETTINGS_JSON='{"permissions":{"allow":["mcp__cog__*","Read(**)","Edit(**)","Grep(**)","Glob(**)","Write(**)","Task(**)","Bash(python3:*)","Bash(docker:*)","Bash(bash:*)","Bash(cd:*)","Bash(./*)","Bash(timeout:*)"]}}'

# ── Process each task ────────────────────────────────────────────────────

echo ""
echo "Setting up workspaces..."

python3 << 'PYEOF'
import json, os, subprocess, sys, textwrap

script_dir = os.environ.get('SCRIPT_DIR', os.path.dirname(os.path.abspath(__file__)))
root_dir = os.environ.get('ROOT_DIR', os.path.join(script_dir, '..', '..'))
workspace = os.environ.get('WORKSPACE', os.path.join(script_dir, 'workspace'))
docker_dir = os.environ.get('DOCKER_DIR', os.path.join(script_dir, 'docker'))
cog = os.environ.get('COG', '')
settings_json = os.environ.get('SETTINGS_JSON', '{}')
tasks_json = os.environ.get('TASKS_JSON', os.path.join(script_dir, 'tasks.json'))

with open(tasks_json) as f:
    tasks = json.load(f)

os.makedirs(workspace, exist_ok=True)
os.makedirs(docker_dir, exist_ok=True)

prompts = []

for task in tasks:
    tid = task['id']
    tag = f"task-{tid:02d}"
    repo = task['repo']
    repo_url = task.get('repo_url', f"https://github.com/{repo}.git")
    base_commit = task['base_commit']
    python_version = task.get('python_version', '3.11')
    install_cmd = task.get('install_cmd', 'pip install -e .')
    test_patch = task.get('test_patch', '')
    test_cmd = task['test_cmd']
    name = task['name']
    problem = task['problem_statement']
    instance_id = task['instance_id']
    fail_to_pass = task.get('fail_to_pass', [])
    pass_to_pass = task.get('pass_to_pass', [])

    task_dir = os.path.join(workspace, tag)
    print(f"\n  [{tag}] {name} ({instance_id})")

    # ── Clone repo ───────────────────────────────────────────────────
    if not os.path.isdir(task_dir):
        print(f"    Cloning {repo}...")
        subprocess.run(
            ['git', 'clone', '--quiet', repo_url, task_dir],
            check=True, timeout=300
        )
    else:
        print(f"    Workspace exists, resetting...")

    # ── Checkout base commit ─────────────────────────────────────────
    print(f"    Checking out {base_commit[:12]}...")
    subprocess.run(
        ['git', 'checkout', '--quiet', base_commit],
        cwd=task_dir, check=True, timeout=30
    )

    # ── Apply test patch ─────────────────────────────────────────────
    if test_patch:
        print(f"    Applying test patch...")
        proc = subprocess.run(
            ['git', 'apply', '--check', '-'],
            input=test_patch, text=True, cwd=task_dir,
            capture_output=True
        )
        if proc.returncode == 0:
            subprocess.run(
                ['git', 'apply', '-'],
                input=test_patch, text=True, cwd=task_dir, check=True
            )
        else:
            print(f"    (test patch already applied or conflicts, skipping)")

    # ── Commit to local branch ───────────────────────────────────────
    print(f"    Creating swedebug-base branch...")
    subprocess.run(
        ['git', 'checkout', '-B', 'swedebug-base'],
        cwd=task_dir, capture_output=True, timeout=10
    )
    subprocess.run(
        ['git', 'add', '-A'],
        cwd=task_dir, capture_output=True, timeout=10
    )
    subprocess.run(
        ['git', 'commit', '--allow-empty', '-m', 'swedebug: base state with test patch'],
        cwd=task_dir, capture_output=True, timeout=10,
        env={**os.environ, 'GIT_AUTHOR_NAME': 'swedebug', 'GIT_AUTHOR_EMAIL': 'bench@cog',
             'GIT_COMMITTER_NAME': 'swedebug', 'GIT_COMMITTER_EMAIL': 'bench@cog'}
    )

    # ── Generate Dockerfile ──────────────────────────────────────────
    dockerfile_path = os.path.join(docker_dir, f"{tag}.Dockerfile")
    print(f"    Generating {tag}.Dockerfile...")

    # Determine extra apt packages based on repo
    extra_apt = ""
    if "scikit-learn" in repo:
        extra_apt = " gfortran libopenblas-dev"

    dockerfile = textwrap.dedent(f"""\
        FROM python:{python_version}-slim
        RUN apt-get update && apt-get install -y git gcc g++{extra_apt} && rm -rf /var/lib/apt/lists/*
        WORKDIR /testbed
        COPY workspace/{tag}/setup.py* workspace/{tag}/setup.cfg* workspace/{tag}/pyproject.toml* /tmp/setup/
        RUN {install_cmd.replace('/testbed', '/tmp/setup').replace('-e .', '-e /tmp/setup')} 2>/dev/null || true
        RUN pip install debugpy pytest
        CMD ["sleep", "infinity"]
    """)
    with open(dockerfile_path, 'w') as f:
        f.write(dockerfile)

    # ── Configure .mcp.json and .claude/settings.json ────────────────
    mcp_config = json.dumps({
        "mcpServers": {
            "cog": {"command": cog, "args": ["mcp"]}
        }
    })
    with open(os.path.join(task_dir, '.mcp.json'), 'w') as f:
        f.write(mcp_config)

    claude_dir = os.path.join(task_dir, '.claude')
    os.makedirs(claude_dir, exist_ok=True)
    with open(os.path.join(claude_dir, 'settings.json'), 'w') as f:
        f.write(settings_json)

    # ── Build prompt blocks ──────────────────────────────────────────
    fail_tests_str = ', '.join(fail_to_pass[:3])
    problem_summary = problem[:500] if len(problem) > 500 else problem

    debug_prompt = textwrap.dedent(f"""\
You have access to the cog debugger via cog_debug_* MCP tools. Use the debugger to diagnose and fix the bug.

This is a real bug from {repo} ({instance_id}). The repo is in the current directory at the buggy commit.

Run tests via: docker exec swedebug-{tag} bash -c "cd /testbed && {test_cmd}"

**Problem**: {problem_summary}

The failing test(s): {fail_tests_str}

The test currently FAILS. Use the debugger to set breakpoints, inspect runtime state, and diagnose the root cause. Fix the source code and verify the test passes.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/swe-{tid}-debug.json in this format: {{"test": {tid}, "name": "{name}", "variant": "debug", "calls": N, "rounds": N}}

Then run this command to update the dashboard: bash ../collect.sh""")

    trad_prompt = textwrap.dedent(f"""\
You must NOT use any cog_* MCP tools. Diagnose and fix the bug using only standard tools (Read, Grep, Glob, Edit, Bash).

This is a real bug from {repo} ({instance_id}). The repo is in the current directory at the buggy commit.

Run tests via: docker exec swedebug-{tag} bash -c "cd /testbed && {test_cmd}"

**Problem**: {problem_summary}

The failing test(s): {fail_tests_str}

The test currently FAILS. Diagnose the root cause, fix the source code, and verify the test passes.

After fixing, count your tool calls and LLM rounds. Write the result as JSON to ../.bench/swe-{tid}-traditional.json in this format: {{"test": {tid}, "name": "{name}", "variant": "traditional", "calls": N, "rounds": N}}

Then run this command to update the dashboard: bash ../collect.sh""")

    prompts.append({
        'id': tid,
        'name': name,
        'instance_id': instance_id,
        'debug': debug_prompt,
        'traditional': trad_prompt,
    })

# ── Generate swedebug.md ────────────────────────────────────────────────
print(f"\n  Generating swedebug.md...")
md_lines = [
    "# SWE-bench — Debug Benchmark\n",
    f"\n{len(tasks)} real-world GitHub issues from SWE-bench Verified.\n",
    "\n---\n",
]

for p in prompts:
    md_lines.append(f"\n## Task {p['id']}: {p['name']} ({p['instance_id']})\n")
    md_lines.append(f"\n### Debug variant\n```\n{p['debug']}\n```\n")
    md_lines.append(f"\n### Traditional variant\n```\n{p['traditional']}\n```\n")
    md_lines.append("\n---\n")

md_path = os.path.join(script_dir, 'swedebug.md')
with open(md_path, 'w') as f:
    f.writelines(md_lines)

print(f"\n  Generated {len(prompts)} task prompts in swedebug.md")
PYEOF

# ── Build Docker images ──────────────────────────────────────────────────

echo ""
echo "Building Docker images..."

task_ids=$(python3 -c "import json; [print(t['id']) for t in json.load(open('$TASKS_JSON'))]")
for tid in $task_ids; do
  tag=$(printf "task-%02d" "$tid")
  dockerfile="$DOCKER_DIR/$tag.Dockerfile"

  if [[ ! -f "$dockerfile" ]]; then
    echo "  SKIP $tag: no Dockerfile"
    continue
  fi

  echo "  Building swedebug-$tag..."
  if docker build -f "$dockerfile" -t "swedebug-$tag" "$SCRIPT_DIR" -q 2>&1 | tail -1; then
    echo "  swedebug-$tag: OK"
  else
    echo "  swedebug-$tag: FAILED (check Dockerfile)"
  fi
done

# ── Smoke test ───────────────────────────────────────────────────────────

echo ""
echo "Smoke testing..."

for tid in $task_ids; do
  tag=$(printf "task-%02d" "$tid")
  task_dir="$WORKSPACE/$tag"

  if [[ ! -d "$task_dir" ]]; then
    echo "  SKIP $tag: no workspace"
    continue
  fi

  result=$(docker run --rm -v "$task_dir:/testbed" "swedebug-$tag" python -c "import sys; print(f'Python {sys.version}')" 2>&1 || true)
  if echo "$result" | grep -q "Python"; then
    echo "  $tag: $result"
  else
    echo "  $tag: FAILED smoke test"
  fi
done

# ── Create .bench directory ──────────────────────────────────────────────

mkdir -p "$SCRIPT_DIR/.bench"

echo ""
echo "═══════════════════════════════════════"
echo "  Setup complete!"
echo "═══════════════════════════════════════"
echo ""
echo "Run benchmarks:"
echo "  bash bench/swedebug/run.sh                  # all tasks, all variants"
echo "  bash bench/swedebug/run.sh 1 debug          # single task, single variant"
echo "  bash bench/swedebug/run.sh '1 2 3' debug    # multiple tasks"
echo ""
echo "View results:"
echo "  open bench/swedebug/dashboard.html"
