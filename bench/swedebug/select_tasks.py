#!/usr/bin/env python3
"""
Select SWE-bench Verified tasks suitable for debugger benchmarking.

Downloads the SWE-bench Verified dataset from HuggingFace and filters for
tasks that are debugger-friendly:
  - From well-supported repos (django, sympy, scikit-learn)
  - Single-file patches (one diff --git block)
  - Small patches (< 2000 chars)
  - Clear problem statements (> 40 words)

Usage:
    pip install datasets  # one-time
    python3 bench/swedebug/select_tasks.py

Output: prints candidate tasks for manual review, sorted by patch size.
Pick 5 and add them to tasks.json.
"""

import json
import re
import sys

try:
    from datasets import load_dataset
except ImportError:
    print("Install the datasets library first:")
    print("  pip install datasets")
    sys.exit(1)

# Repos with good Docker support and well-understood test infrastructure
TARGET_REPOS = {
    "django/django",
    "sympy/sympy",
    "scikit-learn/scikit-learn",
}

# Python version defaults by repo (can be overridden per task)
REPO_PYTHON = {
    "django/django": "3.11",
    "sympy/sympy": "3.9",
    "scikit-learn/scikit-learn": "3.9",
}


def count_diff_blocks(patch: str) -> int:
    """Count the number of diff --git blocks in a patch."""
    return len(re.findall(r"^diff --git ", patch, re.MULTILINE))


def word_count(text: str) -> int:
    return len(text.split())


def extract_changed_file(patch: str) -> str:
    """Extract the single changed file path from a 1-file patch."""
    m = re.search(r"^diff --git a/(.+?) b/", patch, re.MULTILINE)
    return m.group(1) if m else ""


def main():
    print("Loading SWE-bench Verified dataset...", file=sys.stderr)
    ds = load_dataset("princeton-nlp/SWE-bench_Verified", split="test")
    print(f"Total entries: {len(ds)}", file=sys.stderr)

    candidates = []
    for row in ds:
        repo = row["repo"]
        if repo not in TARGET_REPOS:
            continue

        patch = row.get("patch", "")
        problem = row.get("problem_statement", "")

        # Single-file patch
        if count_diff_blocks(patch) != 1:
            continue

        # Small patch
        if len(patch) > 2000:
            continue

        # Clear problem statement
        if word_count(problem) < 40:
            continue

        # Must have FAIL_TO_PASS tests
        fail_to_pass = row.get("FAIL_TO_PASS", "")
        if isinstance(fail_to_pass, str):
            try:
                fail_to_pass = json.loads(fail_to_pass)
            except (json.JSONDecodeError, TypeError):
                fail_to_pass = [fail_to_pass] if fail_to_pass else []

        if not fail_to_pass:
            continue

        pass_to_pass = row.get("PASS_TO_PASS", "")
        if isinstance(pass_to_pass, str):
            try:
                pass_to_pass = json.loads(pass_to_pass)
            except (json.JSONDecodeError, TypeError):
                pass_to_pass = [pass_to_pass] if pass_to_pass else []

        test_patch = row.get("test_patch", "")
        changed_file = extract_changed_file(patch)

        candidates.append({
            "instance_id": row["instance_id"],
            "repo": repo,
            "base_commit": row.get("base_commit", ""),
            "python_version": row.get("environment_setup_commit", REPO_PYTHON.get(repo, "3.11")),
            "changed_file": changed_file,
            "patch_size": len(patch),
            "problem_words": word_count(problem),
            "problem_statement": problem[:200] + "..." if len(problem) > 200 else problem,
            "fail_to_pass": fail_to_pass,
            "pass_to_pass": pass_to_pass[:3],  # truncate for display
            "patch": patch,
            "test_patch": test_patch[:500] + "..." if len(test_patch) > 500 else test_patch,
            "hints_text": (row.get("hints_text", "") or "")[:100],
        })

    # Sort by patch size (simpler patches first)
    candidates.sort(key=lambda c: c["patch_size"])

    print(f"\nFound {len(candidates)} candidates\n", file=sys.stderr)
    print(f"{'#':>3}  {'Instance ID':<40} {'Repo':<30} {'File':<50} {'Patch':>5} {'Words':>5}")
    print("-" * 135)

    for i, c in enumerate(candidates, 1):
        print(f"{i:>3}  {c['instance_id']:<40} {c['repo']:<30} {c['changed_file']:<50} {c['patch_size']:>5} {c['problem_words']:>5}")

    # Print detailed info for top 20
    print(f"\n\n{'='*80}")
    print("TOP 20 CANDIDATES (sorted by patch size)")
    print(f"{'='*80}\n")

    for i, c in enumerate(candidates[:20], 1):
        print(f"--- #{i}: {c['instance_id']} ---")
        print(f"  Repo: {c['repo']}")
        print(f"  File: {c['changed_file']}")
        print(f"  Patch size: {c['patch_size']} chars")
        print(f"  Problem: {c['problem_statement']}")
        print(f"  FAIL_TO_PASS: {c['fail_to_pass']}")
        if c["hints_text"]:
            print(f"  Hints: {c['hints_text']}")
        print()

    # Output JSON for easy consumption
    json_file = "bench/swedebug/candidates.json"
    with open(json_file, "w") as f:
        json.dump(candidates, f, indent=2)
    print(f"\nFull candidate list written to {json_file}", file=sys.stderr)
    print(f"\nPick 5 tasks and format them for tasks.json. Example:", file=sys.stderr)
    print("""
  {
    "id": 1,
    "instance_id": "django__django-NNNNN",
    "repo": "django/django",
    "repo_url": "https://github.com/django/django.git",
    "base_commit": "<sha>",
    "python_version": "3.11",
    "name": "Short description",
    "problem_statement": "Full issue text...",
    "test_cmd": "python -m pytest tests/path -xvs",
    "fail_to_pass": ["tests/path::test_method"],
    "pass_to_pass": ["tests/path::test_other"],
    "install_cmd": "pip install -e .",
    "test_patch": "<unified diff from SWE-bench>",
    "gold_patch": "<unified diff from SWE-bench>"
  }
""", file=sys.stderr)


if __name__ == "__main__":
    main()
