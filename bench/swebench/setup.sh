#!/usr/bin/env bash
# Setup script for SWE-bench Pro benchmarks (Docker-based)
# Pulls Docker images, extracts source to host workspaces, starts containers with bind mounts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASKS_JSON="$SCRIPT_DIR/tasks.json"
WORKSPACE="$SCRIPT_DIR/workspace"

echo "═══════════════════════════════════════"
echo "  SWE-bench Pro Benchmark Setup"
echo "═══════════════════════════════════════"
echo ""

# ── Generate tasks.json if missing ───────────────────────────────────────

if [[ ! -f "$TASKS_JSON" ]]; then
  echo "tasks.json not found, generating..."
  echo ""
  pip install --quiet datasets 2>/dev/null
  python3 "$SCRIPT_DIR/select_tasks_pro.py"
  echo ""
fi

task_count=$(python3 -c "import json; print(len(json.load(open('$TASKS_JSON'))))")
if [[ "$task_count" -eq 0 ]]; then
  echo "ERROR: tasks.json is empty. select_tasks_pro.py may have failed."
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

if ! docker info &>/dev/null; then
  echo "  ERROR: Docker daemon is not running"
  exit 1
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

echo "  docker:   $(docker --version 2>&1 | head -1)"
echo "  python3:  $(python3 --version 2>&1)"
echo "  git:      $(git --version 2>&1)"
echo "  claude:   $(claude --version 2>&1 | head -1)"

# ── Settings ─────────────────────────────────────────────────────────────

SETTINGS_JSON='{"permissions":{"allow":["mcp__cog__*","Read(**)","Edit(**)","Grep(**)","Glob(**)","Write(**)","Task(**)","Bash(python3:*)","Bash(docker:*)","Bash(bash:*)","Bash(cd:*)","Bash(./*)","Bash(timeout:*)","Bash(git:*)"]}}'

# ── Process each task ────────────────────────────────────────────────────

echo ""
echo "Setting up workspaces..."

export SCRIPT_DIR ROOT_DIR WORKSPACE TASKS_JSON SETTINGS_JSON

python3 -u << 'PYEOF'
import json, os, re, subprocess, sys

script_dir = os.environ['SCRIPT_DIR']
workspace = os.environ['WORKSPACE']
settings_json = os.environ['SETTINGS_JSON']
tasks_json = os.environ['TASKS_JSON']

with open(tasks_json) as f:
    tasks = json.load(f)

os.makedirs(workspace, exist_ok=True)

for i, task in enumerate(tasks):
    instance_id = task['instance_id']
    repo = task['repo']
    test_patch = task.get('test_patch', '')
    dockerhub_tag = task.get('dockerhub_tag', '')
    before_repo_set_cmd = task.get('before_repo_set_cmd', '')

    task_dir = os.path.join(workspace, instance_id)
    print(f"\n  [{i+1}/{len(tasks)}] {instance_id}")

    image = f"jefzda/sweap-images:{dockerhub_tag}"
    container_name = f"swebench-{instance_id}"

    # ── Pull Docker image ────────────────────────────────────────────
    print(f"    Pulling image {image}...")
    proc = subprocess.run(
        ['docker', 'pull', image],
        capture_output=True, text=True, timeout=600
    )
    if proc.returncode != 0:
        print(f"    ERROR pulling image: {proc.stderr.strip()}")
        continue

    # ── Extract source from image to host workspace ──────────────────
    if not os.path.isdir(task_dir):
        print(f"    Extracting /testbed to workspace...")
        # Create a temporary container to copy files from
        tmp_name = f"swebench-extract-{instance_id}"
        subprocess.run(
            ['docker', 'rm', '-f', tmp_name],
            capture_output=True, timeout=30
        )
        proc = subprocess.run(
            ['docker', 'create', '--name', tmp_name, image, 'true'],
            capture_output=True, text=True, timeout=60
        )
        if proc.returncode != 0:
            print(f"    ERROR creating extract container: {proc.stderr.strip()}")
            continue

        os.makedirs(task_dir, exist_ok=True)
        proc = subprocess.run(
            ['docker', 'cp', f'{tmp_name}:/testbed/.', task_dir],
            capture_output=True, text=True, timeout=300
        )
        if proc.returncode != 0:
            print(f"    ERROR copying /testbed: {proc.stderr.strip()}")
            subprocess.run(['docker', 'rm', '-f', tmp_name], capture_output=True, timeout=30)
            continue

        subprocess.run(
            ['docker', 'rm', '-f', tmp_name],
            capture_output=True, timeout=30
        )
    else:
        print(f"    Workspace exists, reusing...")

    # ── Init git in host workspace ───────────────────────────────────
    git_dir = os.path.join(task_dir, '.git')
    if not os.path.isdir(git_dir):
        print(f"    Initializing git repo...")
        git_env = {
            **os.environ,
            'GIT_AUTHOR_NAME': 'swebench',
            'GIT_AUTHOR_EMAIL': 'bench@cog',
            'GIT_COMMITTER_NAME': 'swebench',
            'GIT_COMMITTER_EMAIL': 'bench@cog',
        }
        subprocess.run(['git', 'init'], cwd=task_dir, capture_output=True, timeout=30)
        subprocess.run(['git', 'add', '-A'], cwd=task_dir, capture_output=True, timeout=60)
        subprocess.run(
            ['git', 'commit', '--allow-empty', '-m', 'initial: extracted from Docker image'],
            cwd=task_dir, capture_output=True, timeout=30, env=git_env
        )

    # ── Stop existing container if running ───────────────────────────
    subprocess.run(
        ['docker', 'rm', '-f', container_name],
        capture_output=True, timeout=30
    )

    # ── Start container with bind mount ──────────────────────────────
    print(f"    Starting container {container_name}...")
    proc = subprocess.run(
        ['docker', 'run', '-d',
         '--name', container_name,
         '-v', f'{task_dir}:/testbed',
         '-w', '/testbed',
         image, 'sleep', 'infinity'],
        capture_output=True, text=True, timeout=60
    )
    if proc.returncode != 0:
        print(f"    ERROR starting container: {proc.stderr.strip()}")
        continue

    # ── Run before_repo_set_cmd if present ───────────────────────────
    if before_repo_set_cmd and before_repo_set_cmd.strip():
        print(f"    Running setup commands...")
        proc = subprocess.run(
            ['docker', 'exec', container_name, 'bash', '-c', before_repo_set_cmd],
            capture_output=True, text=True, timeout=600
        )
        if proc.returncode != 0:
            print(f"    WARNING: setup command failed: {proc.stderr.strip()[:200]}")

    # ── Install debugpy in container ─────────────────────────────────
    print(f"    Installing debugpy...")
    subprocess.run(
        ['docker', 'exec', container_name, 'pip', 'install', 'debugpy'],
        capture_output=True, text=True, timeout=120
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

    # ── Sanitize pytest addopts ──────────────────────────────────────
    for cfg_name in ['setup.cfg', 'pytest.ini']:
        cfg_path = os.path.join(task_dir, cfg_name)
        if os.path.exists(cfg_path):
            with open(cfg_path) as f:
                content = f.read()
            new_content = re.sub(r'^addopts\s*=.*$', 'addopts =', content, flags=re.MULTILINE)
            if new_content != content:
                with open(cfg_path, 'w') as f:
                    f.write(new_content)
                print(f"    Sanitized addopts in {cfg_name}")
    pyproject_path = os.path.join(task_dir, 'pyproject.toml')
    if os.path.exists(pyproject_path):
        with open(pyproject_path) as f:
            content = f.read()
        new_content = re.sub(r'^addopts\s*=.*$', 'addopts = ""', content, flags=re.MULTILINE)
        if new_content != content:
            with open(pyproject_path, 'w') as f:
                f.write(new_content)
            print(f"    Sanitized addopts in pyproject.toml")

    # ── Configure .claude/settings.json ──────────────────────────────
    claude_dir = os.path.join(task_dir, '.claude')
    os.makedirs(claude_dir, exist_ok=True)
    with open(os.path.join(claude_dir, 'settings.json'), 'w') as f:
        f.write(settings_json)

    # ── Install cog-debug agent file ──────────────────────────────────
    agents_dir = os.path.join(claude_dir, 'agents')
    os.makedirs(agents_dir, exist_ok=True)
    debug_agent_header = """\
---
name: cog-debug
description: Stateless debug observation tool — takes exact breakpoint coordinates and returns runtime values
tools:
  - mcp__cog__cog_debug_launch
  - mcp__cog__cog_debug_breakpoint
  - mcp__cog__cog_debug_run
  - mcp__cog__cog_debug_inspect
  - mcp__cog__cog_debug_stacktrace
  - mcp__cog__cog_debug_stop
mcpServers:
  - cog
maxTurns: 10
---
"""
    debug_agent_body_path = os.path.join(script_dir, '..', '..', 'priv', 'agents', 'cog-debug.md')
    with open(debug_agent_body_path) as f:
        debug_agent_body = f.read()
    with open(os.path.join(agents_dir, 'cog-debug.md'), 'w') as f:
        f.write(debug_agent_header + debug_agent_body)

    # ── Create python3 wrapper for Docker exec ───────────────────────
    bench_bin_dir = os.path.join(task_dir, '.bench', 'bin')
    os.makedirs(bench_bin_dir, exist_ok=True)
    wrapper_path = os.path.join(bench_bin_dir, 'python3')
    with open(wrapper_path, 'w') as f:
        f.write(f'''#!/bin/bash
exec docker exec -i "{container_name}" python3 "$@"
''')
    os.chmod(wrapper_path, 0o755)
    print(f"    Created python3 wrapper at .bench/bin/python3")

    # ── Save container name ──────────────────────────────────────────
    bench_dir = os.path.join(task_dir, '.bench')
    os.makedirs(bench_dir, exist_ok=True)
    with open(os.path.join(bench_dir, 'container.txt'), 'w') as f:
        f.write(container_name)

    # ── Commit to swebench-base branch ───────────────────────────────
    print(f"    Creating swebench-base branch...")
    git_env = {
        **os.environ,
        'GIT_AUTHOR_NAME': 'swebench',
        'GIT_AUTHOR_EMAIL': 'bench@cog',
        'GIT_COMMITTER_NAME': 'swebench',
        'GIT_COMMITTER_EMAIL': 'bench@cog',
    }
    subprocess.run(
        ['git', 'checkout', '-B', 'swebench-base'],
        cwd=task_dir, capture_output=True, timeout=10
    )
    subprocess.run(
        ['git', 'add', '-A'],
        cwd=task_dir, capture_output=True, timeout=10
    )
    subprocess.run(
        ['git', 'commit', '--allow-empty', '-m', 'swebench: base state with test patch'],
        cwd=task_dir, capture_output=True, timeout=10, env=git_env
    )

    print(f"    Done")

print(f"\n  All {len(tasks)} workspaces ready")
PYEOF

# ── Create output directories ────────────────────────────────────────────

mkdir -p "$SCRIPT_DIR/.bench"
mkdir -p "$SCRIPT_DIR/predictions"
mkdir -p "$SCRIPT_DIR/results"

echo ""
echo "═══════════════════════════════════════"
echo "  Setup complete!"
echo "═══════════════════════════════════════"
echo ""
echo "Run benchmarks:"
echo "  bash bench/swebench/run.sh all              # all tasks, all variants"
echo "  bash bench/swebench/run.sh baseline 2       # baseline only, first 2 tasks"
echo "  bash bench/swebench/run.sh debugger 2       # debugger only, first 2 tasks"
echo ""
echo "View results:"
echo "  bash bench/swebench/evaluate.sh"
echo "  bash bench/swebench/collect.sh"
echo "  open bench/swebench/dashboard.html"
echo ""
echo "Cleanup containers:"
echo "  bash bench/swebench/cleanup.sh"
