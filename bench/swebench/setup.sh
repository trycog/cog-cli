#!/usr/bin/env bash
# Setup script for SWE-bench Lite benchmarks
# Clones repos, creates workspaces, configures Claude permissions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASKS_JSON="$SCRIPT_DIR/tasks.json"
WORKSPACE="$SCRIPT_DIR/workspace"
REPOS_CACHE="$WORKSPACE/.repos"

echo "═══════════════════════════════════════"
echo "  SWE-bench Lite Benchmark Setup"
echo "═══════════════════════════════════════"
echo ""

# ── Validate tasks.json ──────────────────────────────────────────────────

if [[ ! -f "$TASKS_JSON" ]]; then
  echo "ERROR: tasks.json not found."
  echo ""
  echo "Run select_tasks.py first:"
  echo "  pip install datasets"
  echo "  python3 bench/swebench/select_tasks.py"
  exit 1
fi

task_count=$(python3 -c "import json; print(len(json.load(open('$TASKS_JSON'))))")
if [[ "$task_count" -eq 0 ]]; then
  echo "ERROR: tasks.json is empty."
  echo ""
  echo "Run select_tasks.py first:"
  echo "  pip install datasets"
  echo "  python3 bench/swebench/select_tasks.py"
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

if ! python3 -c "import swebench" 2>/dev/null; then
  missing+=("swebench (pip install swebench)")
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
echo "  swebench: $(python3 -c 'import swebench; print(swebench.__version__)' 2>/dev/null || echo 'installed')"

# ── Settings ─────────────────────────────────────────────────────────────

SETTINGS_JSON='{"permissions":{"allow":["mcp__cog__*","Read(**)","Edit(**)","Grep(**)","Glob(**)","Write(**)","Task(**)","Bash(python3:*)","Bash(docker:*)","Bash(bash:*)","Bash(cd:*)","Bash(./*)","Bash(timeout:*)","Bash(git:*)"]}}'

# ── Process each task ────────────────────────────────────────────────────

echo ""
echo "Setting up workspaces..."

export SCRIPT_DIR ROOT_DIR WORKSPACE REPOS_CACHE TASKS_JSON SETTINGS_JSON

python3 -u << 'PYEOF'
import json, os, re, subprocess, sys

script_dir = os.environ['SCRIPT_DIR']
workspace = os.environ['WORKSPACE']
repos_cache = os.environ['REPOS_CACHE']
settings_json = os.environ['SETTINGS_JSON']
tasks_json = os.environ['TASKS_JSON']

with open(tasks_json) as f:
    tasks = json.load(f)

os.makedirs(workspace, exist_ok=True)
os.makedirs(repos_cache, exist_ok=True)

for i, task in enumerate(tasks):
    instance_id = task['instance_id']
    repo = task['repo']
    base_commit = task['base_commit']
    test_patch = task.get('test_patch', '')

    task_dir = os.path.join(workspace, instance_id)
    print(f"\n  [{i+1}/{len(tasks)}] {instance_id}")

    # ── Shared bare clone cache ──────────────────────────────────────
    repo_slug = repo.replace('/', '__')
    bare_dir = os.path.join(repos_cache, repo_slug)
    repo_url = f"https://github.com/{repo}.git"

    if not os.path.isdir(bare_dir):
        print(f"    Cloning bare cache for {repo}...")
        subprocess.run(
            ['git', 'clone', '--bare', '--quiet', repo_url, bare_dir],
            check=True, timeout=600
        )
    else:
        print(f"    Bare cache exists for {repo}")

    # ── Clone workspace using reference ──────────────────────────────
    if not os.path.isdir(task_dir):
        print(f"    Cloning workspace (with --reference)...")
        subprocess.run(
            ['git', 'clone', '--quiet', '--reference', bare_dir, repo_url, task_dir],
            check=True, timeout=300
        )
    else:
        print(f"    Workspace exists, resetting...")

    # ── Checkout base commit ─────────────────────────────────────────
    print(f"    Checking out {base_commit[:12]}...")
    subprocess.run(
        ['git', 'checkout', '--quiet', '--force', base_commit],
        cwd=task_dir, check=True, timeout=30
    )
    subprocess.run(
        ['git', 'clean', '-fd', '--quiet'],
        cwd=task_dir, capture_output=True, timeout=30
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
    # Remove plugin-specific flags (e.g. --doctest-rst) that cause pytest
    # to exit with code 4 when the plugin isn't installed.
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

    # ── Commit to swebench-base branch ───────────────────────────────
    print(f"    Creating swebench-base branch...")
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
        cwd=task_dir, capture_output=True, timeout=10,
        env={**os.environ, 'GIT_AUTHOR_NAME': 'swebench', 'GIT_AUTHOR_EMAIL': 'bench@cog',
             'GIT_COMMITTER_NAME': 'swebench', 'GIT_COMMITTER_EMAIL': 'bench@cog'}
    )

    # ── Configure .claude/settings.json ──────────────────────────────
    claude_dir = os.path.join(task_dir, '.claude')
    os.makedirs(claude_dir, exist_ok=True)
    with open(os.path.join(claude_dir, 'settings.json'), 'w') as f:
        f.write(settings_json)

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
