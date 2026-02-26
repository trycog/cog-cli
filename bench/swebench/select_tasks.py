#!/usr/bin/env python3
"""
Select 100 tasks from SWE-bench Lite for debugger benchmarking.

Downloads the SWE-bench Lite dataset from HuggingFace, filters for valid tasks,
and randomly samples 100 with a fixed seed for reproducibility.

Usage:
    pip install datasets  # one-time
    python3 bench/swebench/select_tasks.py

Output: bench/swebench/tasks.json with 100 task definitions.
"""

import json
import random
import sys
import os

try:
    from datasets import load_dataset
except ImportError:
    print("Install the datasets library first:")
    print("  pip install datasets")
    sys.exit(1)


def main():
    print("Loading SWE-bench Lite dataset...", file=sys.stderr)
    ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
    print(f"Total entries: {len(ds)}", file=sys.stderr)

    valid = []
    skipped = {"no_patch": 0, "no_commit": 0, "no_fail": 0, "no_problem": 0}

    for row in ds:
        patch = row.get("patch", "") or ""
        base_commit = row.get("base_commit", "") or ""
        problem = row.get("problem_statement", "") or ""

        # Must have a non-empty patch
        if not patch.strip():
            skipped["no_patch"] += 1
            continue

        # Must have a base commit
        if not base_commit.strip():
            skipped["no_commit"] += 1
            continue

        # Must have a problem statement
        if not problem.strip():
            skipped["no_problem"] += 1
            continue

        # Parse FAIL_TO_PASS
        fail_to_pass = row.get("FAIL_TO_PASS", "")
        if isinstance(fail_to_pass, str):
            try:
                fail_to_pass = json.loads(fail_to_pass)
            except (json.JSONDecodeError, TypeError):
                fail_to_pass = [fail_to_pass] if fail_to_pass else []

        if not fail_to_pass:
            skipped["no_fail"] += 1
            continue

        # Parse PASS_TO_PASS
        pass_to_pass = row.get("PASS_TO_PASS", "")
        if isinstance(pass_to_pass, str):
            try:
                pass_to_pass = json.loads(pass_to_pass)
            except (json.JSONDecodeError, TypeError):
                pass_to_pass = [pass_to_pass] if pass_to_pass else []

        test_patch = row.get("test_patch", "") or ""
        version = row.get("version", "") or ""

        valid.append({
            "instance_id": row["instance_id"],
            "repo": row["repo"],
            "base_commit": base_commit,
            "patch": patch,
            "test_patch": test_patch,
            "problem_statement": problem,
            "FAIL_TO_PASS": fail_to_pass,
            "PASS_TO_PASS": pass_to_pass,
            "version": version,
        })

    print(f"Valid tasks: {len(valid)}", file=sys.stderr)
    print(f"Skipped: {skipped}", file=sys.stderr)

    # Reproducible random sample of 100
    random.seed(42)
    if len(valid) > 100:
        selected = random.sample(valid, 100)
    else:
        selected = valid
        print(f"Warning: only {len(valid)} valid tasks (wanted 100)", file=sys.stderr)

    # Sort by instance_id for stable ordering
    selected.sort(key=lambda t: t["instance_id"])

    # Write output
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(script_dir, "tasks.json")
    with open(out_path, "w") as f:
        json.dump(selected, f, indent=2)

    print(f"\nWrote {len(selected)} tasks to {out_path}", file=sys.stderr)

    # Summary by repo
    repos = {}
    for t in selected:
        repos[t["repo"]] = repos.get(t["repo"], 0) + 1
    print("\nTasks per repo:", file=sys.stderr)
    for repo, count in sorted(repos.items(), key=lambda x: -x[1]):
        print(f"  {repo}: {count}", file=sys.stderr)


if __name__ == "__main__":
    main()
